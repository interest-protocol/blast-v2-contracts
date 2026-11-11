#!/usr/bin/env python3
"""Compare fee grids using isolated builds of the actual Move source.

Only BANDS_PER_SIDE changes between builds. Generated tests assert the Python
integer replica's exact step, net-input and fee totals. Sui test statistics
measure the pinned CLI's Sui VM meter, not a complete PTB or storage access.
"""

from __future__ import annotations

import argparse
from decimal import Decimal, localcontext
import hashlib
import json
from math import isqrt
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "scratch-sui/dex/sources/fees/lp_fee.move"
Q96 = 1 << 96
Q32 = 1 << 32
DENOMINATOR = 1_000_000
COUNTS = (64, 128, 512)


def ceil_div(numerator: int, denominator: int) -> int:
    return (numerator + denominator - 1) // denominator


def sqrt_up(value: int) -> int:
    root = isqrt(value)
    return root + (root * root < value)


def widths(base: int, cap: int, sensitivity: int, count: int) -> tuple[int, int]:
    if base == cap:
        return 0, 0
    gap = sqrt_up(ceil_div((cap - base) << 64, sensitivity))
    upper = sqrt_up((Q32 + gap) << 32) - Q32
    lower = Q32 - isqrt((Q32 - gap) << 32)
    return (
        ceil_div(Q96 * upper, Q32 * count),
        ceil_div(Q96 * lower, Q32 * count),
    )


def rate_at(price: int, base: int, cap: int, sensitivity: int) -> int:
    ratio = (
        min((price << 64) // Q96, 512 << 64)
        if price >= Q96 else ceil_div(price << 64, Q96)
    )
    gap = abs(ratio * ratio - (1 << 128)) >> 64
    return min(cap, base + ((sensitivity * gap * gap) >> 128))


def next_step(start: int, limit: int, case: dict, count: int) -> tuple[int, int]:
    upper, lower = widths(case["base"], case["cap"], case["sensitivity"], count)
    if upper == 0:
        return limit, case["base"]
    up = limit > start
    above = start > Q96 or (start == Q96 and up)
    away = above == up
    width = upper if above else lower
    distance = abs(start - Q96)
    band = distance // width + 1 if away else ceil_div(distance, width)
    if band > count:
        edge = count
        rate = case["cap"]
        if away:
            return limit, rate
    else:
        edge = band if away else band - 1
        outer = Q96 + band * width if above else Q96 - band * width
        rate = (
            case["cap"] if band == count
            else rate_at(outer, case["base"], case["cap"], case["sensitivity"])
        )
    boundary = Q96 + edge * width if above else Q96 - edge * width
    return (min(limit, boundary) if up else max(limit, boundary)), rate


def walk(case: dict, count: int) -> dict:
    spot = case["start"]
    boundaries = case["boundaries"]
    up = boundaries[-1] > spot
    index = 0
    total_net = total_fee = steps = 0
    with localcontext() as context:
        context.prec = 60
        real_net = Decimal(0)
        real_fee = Decimal(0)
        while spot != boundaries[-1]:
            end, rate = next_step(spot, boundaries[index], case, count)
            assert end != spot
            liquidity = case["liquidity"] * (1 + index % 2)
            numerator = liquidity * abs(end - spot) * (1 if up else Q96)
            denominator = Q96 if up else spot * end
            net = ceil_div(numerator, denominator)
            fee = ceil_div(net * rate, DENOMINATOR - rate)
            total_net += net
            total_fee += fee
            real_delta = Decimal(numerator) / denominator
            real_net += real_delta
            real_fee += real_delta * rate / (DENOMINATOR - rate)
            spot = end
            steps += 1
            if spot == boundaries[index]:
                index += 1
            assert steps <= 2 * count + len(boundaries) + 2
        return {
            "steps": steps, "net_atoms": total_net, "fee_atoms": total_fee,
            "gross_atoms": total_net + total_fee,
            "real_net_atoms": str(real_net), "real_fee_atoms": str(real_fee),
            "atomic_rounding_extra_atoms": str(
                total_net + total_fee - real_net - real_fee
            ),
        }


def price_sqrt(numerator: int, denominator: int = 1) -> int:
    return isqrt((numerator << 192) // denominator)


def cases() -> list[dict]:
    result = []

    def add(name, start, end, *, base=1000, cap=10000, sensitivity=1000000,
            liquidity=10**9, ticks=1):
        boundaries = [start + (end - start) * index // ticks
                      for index in range(1, ticks + 1)]
        result.append(dict(name=name, start=start, boundaries=boundaries,
                           base=base, cap=cap, sensitivity=sensitivity,
                           liquidity=liquidity))

    add("setup_only", Q96, Q96)
    add("flat", Q96, 2 * Q96, cap=1000)
    for numerator, denominator, label in [(1, 1000, "small"), (1, 100, "one_pct"),
                                          (5, 100, "five_pct"), (10, 100, "ten_pct")]:
        add(label + "_up", Q96, price_sqrt(denominator + numerator, denominator))
        add(label + "_down", Q96, price_sqrt(denominator - numerator, denominator))
    add("toward_reference_up", price_sqrt(95, 100), Q96)
    add("toward_reference_down", price_sqrt(105, 100), Q96)
    add("cross_reference_up", price_sqrt(9, 10), price_sqrt(11, 10))
    add("cross_reference_down", price_sqrt(11, 10), price_sqrt(9, 10))
    add("many_ticks_up", price_sqrt(95, 100), price_sqrt(105, 100), ticks=128)
    add("many_ticks_down", price_sqrt(105, 100), price_sqrt(95, 100), ticks=128)
    add("high_sensitivity_up", Q96, price_sqrt(101, 100),
        cap=100000, sensitivity=100000000)
    add("high_sensitivity_down", Q96, price_sqrt(99, 100),
        cap=100000, sensitivity=100000000)
    add("full_span_up", Q96 // 1000, 3 * Q96 // 2,
        base=1, cap=100000, sensitivity=100000)
    add("full_span_down", 3 * Q96 // 2, Q96 // 1000,
        base=1, cap=100000, sensitivity=100000)
    add("thin_liquidity_up", Q96, price_sqrt(101, 100), liquidity=1000)
    add("thin_liquidity_down", Q96, price_sqrt(99, 100), liquidity=1000)
    return result


def adverse_cases(count: int) -> list[dict]:
    """Each candidate's own last upper band, a reachable high-cap path."""
    base, cap, sensitivity = 1, 100000, 100000
    upper, _ = widths(base, cap, sensitivity, count)
    start = Q96 + (count - 1) * upper
    return [dict(
        name=name, start=start, boundaries=[end], base=base, cap=cap,
        sensitivity=sensitivity, liquidity=10**15,
    ) for name, end in [
        ("adverse_outer_whole_band", Q96 + count * upper),
        ("adverse_outer_partial_band", start + max(1, upper // 1000000)),
    ]]


def smooth_fee(case: dict, tolerance: Decimal) -> Decimal:
    """Independent Decimal60 adaptive integral, split at cap and reference.

    Integrate in net-amount coordinates: t for up, 1/t for down. This avoids
    the down-direction 1/t² near-singularity at very low sqrt-price ratios.
    """
    with localcontext() as context:
        context.prec = 60
        base = Decimal(case["base"]) / DENOMINATOR
        cap = Decimal(case["cap"]) / DENOMINATOR
        sensitivity = Decimal(case["sensitivity"]) / DENOMINATOR
        cap_gap = ((cap - base) / sensitivity).sqrt()
        cap_edges = [(1 - cap_gap).sqrt(), (1 + cap_gap).sqrt()]
        up = case["boundaries"][-1] > case["start"]

        def integrand(coordinate):
            spot = coordinate if up else 1 / coordinate
            rate = min(cap, base + sensitivity * (spot * spot - 1) ** 2)
            return rate / (1 - rate)

        def integrate(left, right):
            def simpson(a, b, fa, fm, fb):
                return (b - a) * (fa + 4 * fm + fb) / 6

            def refine(a, b, fa, fm, fb, whole, allowed, depth):
                middle = (a + b) / 2
                fl = integrand((a + middle) / 2)
                fr = integrand((middle + b) / 2)
                first = simpson(a, middle, fa, fl, fm)
                second = simpson(middle, b, fm, fr, fb)
                difference = first + second - whole
                if abs(difference) <= 15 * allowed:
                    return first + second + difference / 15
                assert depth > 0, "Smooth reference failed to converge"
                return (refine(a, middle, fa, fl, fm, first, allowed / 2, depth - 1)
                        + refine(middle, b, fm, fr, fb, second, allowed / 2, depth - 1))

            fa, fm, fb = integrand(left), integrand((left + right) / 2), integrand(right)
            return refine(left, right, fa, fm, fb,
                          simpson(left, right, fa, fm, fb), tolerance, 40)

        fee = Decimal(0)
        start = case["start"]
        for index, end in enumerate(case["boundaries"]):
            low, high = sorted([Decimal(start) / Q96, Decimal(end) / Q96])
            if low == high:
                continue
            cuts = sorted(set([low, high] + [edge for edge in [Decimal(1), *cap_edges]
                                           if low < edge < high]))
            subtotal = Decimal(0)
            for left, right in zip(cuts, cuts[1:]):
                # Capped regions have a constant fee and an exact elementary integral.
                middle = (left + right) / 2
                if base + sensitivity * (middle * middle - 1) ** 2 >= cap:
                    net = right - left if up else 1 / left - 1 / right
                    subtotal += net * cap / (1 - cap)
                    continue
                coordinates = (left, right) if up else (1 / right, 1 / left)
                subtotal += integrate(*coordinates)
            fee += subtotal * case["liquidity"] * (1 + index % 2)
            start = end
        return +fee


def move_tests(all_cases: list[dict], count: int) -> str:
    declarations = []
    for case in all_cases:
        expected = walk(case, count)
        boundaries = ", ".join(str(value) for value in case["boundaries"])
        declarations.append(f'''#[test]
fun {case['name']}() {{
    let settings = lp_fee::new_dynamic_unchecked_for_testing(
        {case['base']}, {case['cap']}, {case['sensitivity']},
    );
    let path = lp_fee::new_fee_path(settings, ONE_X96);
    let (steps, net, fee) = walk(&path, {case['start']}, vector[{boundaries}], {case['liquidity']});
    assert_eq!(steps, {expected['steps']});
    assert_eq!(net, {expected['net_atoms']});
    assert_eq!(fee, {expected['fee_atoms']});
}}
''')
    return '''#[test_only]
module blast_fun_dex::fee_band_benchmark_tests;

// === Constants ===

const ONE_X96: u256 = 1 << 96;

// === Tests ===

#[test]
fun empty() {}

''' + "\n".join(declarations) + '''
// === Test Helpers ===

fun walk(path: &FeePath, start_x96: u256, boundaries: vector<u256>, liquidity: u256): (u64, u64, u64) {
    let mut spot_x96 = start_x96;
    let end_x96 = boundaries[boundaries.length() - 1];
    let up = end_x96 > spot_x96;
    let mut range_index = 0;
    let mut total_net = 0;
    let mut total_fee = 0;
    let mut steps = 0;
    while (spot_x96 != end_x96) {
        let boundary = boundaries[range_index];
        let active_liquidity = liquidity * (1 + (range_index as u256) % 2);
        let step = path.next_step(spot_x96, boundary);
        let next_x96 = step.limit_x96();
        assert!(next_x96 != spot_x96);
        let delta = spot_x96.diff(next_x96);
        let net = if (up) {
            (active_liquidity * delta).div_ceil(ONE_X96) as u64
        } else {
            (active_liquidity * delta * ONE_X96).div_ceil(spot_x96 * next_x96) as u64
        };
        let fee = step.fee_up(net);
        assert_eq!(step.net_budget_down(net + fee), net);
        total_net = total_net + net;
        total_fee = total_fee + fee;
        steps = steps + 1;
        spot_x96 = next_x96;
        if (spot_x96 == boundary) range_index = range_index + 1;
    };
    (steps, total_net, total_fee)
}

// === Imports ===

use blast_fun_dex::lp_fee::{Self, FeePath};
use std::unit_test::assert_eq;
'''


def run_move(all_cases: list[dict], count: int, output: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix=f"blast-fee-bands-{count}-") as temporary:
        package = Path(temporary)
        original = ROOT / "scratch-sui/dex"
        shutil.copytree(original / "sources", package / "sources")
        manifest = (original / "Move.toml").read_text().replace(
            '"../../sui/governance/admin"', json.dumps(str(ROOT / "sui/governance/admin"))
        )
        (package / "Move.toml").write_text(manifest)
        source = package / "sources/fees/lp_fee.move"
        text, substitutions = re.subn(
            r"const BANDS_PER_SIDE: u256 = \d+;",
            f"const BANDS_PER_SIDE: u256 = {count};", source.read_text(),
        )
        assert substitutions == 1
        source.write_text(text)
        shutil.copytree(original / "tests", package / "tests")
        (package / "tests/fee_band_benchmark_tests.move").write_text(move_tests(all_cases, count))
        command = ["sui", "move", "test", "--path", str(package), "--threads", "1",
                   "--statistics", "csv", "--lint", "--warnings-are-errors",
                   "fee_band_benchmark_tests"]
        completed = subprocess.run(command, text=True, capture_output=True)
        log = completed.stdout + completed.stderr
        (output / f"move-{count}.log").write_text(log)
        if completed.returncode:
            raise RuntimeError(f"Move benchmark {count} failed:\n{log}")
        statistics = {}
        for line in log.splitlines():
            if "::fee_band_benchmark_tests::" not in line:
                continue
            columns = [column.strip() for column in line.strip().split(",")]
            if len(columns) >= 3 and "::" in columns[0]:
                name = columns[0].rsplit("::", 1)[-1]
                statistics[name] = columns[1:]
        assert set(statistics) == {"empty", *(case["name"] for case in all_cases)}
        baseline = int(statistics["empty"][1])
        normalized = {
            name: {
                "elapsed_nanoseconds": int(values[0]),
                "raw_reported_gas": int(values[1]),
                "gas_units_above_empty_test": int(values[1]) - baseline,
            }
            for name, values in statistics.items()
        }
        command[4] = "<isolated-package>"
        return {"command": command, "statistics": normalized,
                "empty_test_raw_reported_gas": baseline}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--numerics-only", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    all_cases = cases()
    report = {
        "schema_version": 1,
        "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "sui_version": subprocess.check_output(["sui", "--version"], text=True).strip(),
        "gas_scope": "Sui Move unit-test VM meter; no PTB bucketing, storage or full swap engine",
        "gas_normalization": (
            "Subtract empty-test reported gas to remove the pinned runner's budget/unit offset. "
            "Includes harness arithmetic, vector boundaries and assertions, including "
            "net_budget_down consistency per step. Elapsed time is not a gas estimate."
        ),
        "input_sha256": {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted((ROOT / "scratch-sui/dex").rglob("*.move"))
            if "build" not in path.parts
        },
        "cases": all_cases,
        "results": {},
    }
    smooth = {}

    def add_smooth(case):
        tolerance = Decimal("1e-21")
        first = smooth_fee(case, tolerance)
        refined = smooth_fee(case, tolerance / 16)
        difference = abs(first - refined)
        assert difference < Decimal("0.000001"), (case["name"], difference)
        smooth[case["name"]] = {
            "fee_atoms": str(refined), "refinement_difference_atoms": str(difference),
            "adaptive_tolerance_per_uncapped_region": str(tolerance / 16),
        }

    for case in all_cases:
        add_smooth(case)
    report["smooth_reference"] = dict(smooth)
    for count in COUNTS:
        candidate_cases = all_cases + adverse_cases(count)
        candidate_smooth = dict(smooth)
        for case in adverse_cases(count):
            add_smooth(case)
            candidate_smooth[case["name"]] = smooth[case["name"]]
        results = {}
        for case in candidate_cases:
            row = walk(case, count)
            net = Decimal(row["real_net_atoms"])
            fee = Decimal(candidate_smooth[case["name"]]["fee_atoms"])
            row["sampling_gross_excess_bps"] = str(
                (Decimal(row["real_fee_atoms"]) - fee) / (net + fee) * 10000
                if net + fee else Decimal(0)
            )
            results[case["name"]] = row
        report["results"][str(count)] = {
            "cases": results, "candidate_specific_cases": adverse_cases(count),
            "smooth_reference": candidate_smooth,
        }
        if not args.numerics_only:
            report["results"][str(count)]["move"] = run_move(candidate_cases, count, args.output)
        (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Completed {count} bands", flush=True)


if __name__ == "__main__":
    main()
