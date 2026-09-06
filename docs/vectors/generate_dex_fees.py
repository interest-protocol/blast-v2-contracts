#!/usr/bin/env python3
"""Regenerate DEX reference vectors from exact rational integral and Decimal decay."""
from decimal import Decimal, ROUND_CEILING, getcontext
from fractions import Fraction
import json
from pathlib import Path

getcontext().prec = 110
X32 = 1 << 32
X64 = 1 << 64
MAX = (1 << 64) - 1
BASE = int((Decimal(2) ** (-Decimal(1) / 1800) * X64).to_integral_value(rounding=ROUND_CEILING))


def ceil(value):
    return -(-value.numerator // value.denominator)


def fee(score, target, quote, bps):
    volume = Fraction(score, X32)
    ramp = min(Fraction(quote), target - volume)
    return ceil(Fraction(bps, 10000) * (ramp * (2 * volume + ramp) / (2 * target) + quote - ramp))


def decay(score, elapsed):
    if elapsed >= 129 * 1800:
        return 0
    whole, seconds = divmod(elapsed, 1800)
    factor, base = X64, BASE
    while seconds:
        if seconds % 2:
            factor = ceil(Fraction(factor * base, X64))
        seconds //= 2
        if seconds:
            base = ceil(Fraction(base * base, X64))
    return score * factor // (X64 << whole)


cases = [(0, 1000, q, 500) for q in [0, 1, 100, 999, 1000, 1001, 2000]]
cases += [(500 * X32, 1000, 1000, 500), (1000 * X32, 1000, 1000, 500), (1, 1000, 1000, 500)]
cases += [(0, MAX, MAX, 500), (MAX * X32, MAX, MAX, 500), (0, 1, MAX, 500), (0, 1, MAX, 0)]
fee_rows = [dict(volume_x32=str(v), target=str(t), principal=str(q), max_bps=b, fee=str(fee(v, t, q, b))) for v, t, q, b in cases]
decay_rows = []
for elapsed in [0, 1, 1799, 1800, 1801, 3600, 95 * 1800, 96 * 1800, 129 * 1800]:
    score = MAX * X32
    exact = Decimal(score) * Decimal(2) ** (-Decimal(elapsed) / 1800)
    observed = decay(score, elapsed)
    assert Decimal(observed) > exact - 1
    assert Decimal(observed) - exact < Decimal(score) * 3600 / X64 + 1
    decay_rows.append(dict(volume_x32=str(score), elapsed_seconds=elapsed, result_x32=str(observed), exact_x32=str(exact)))

# Exercise all fractional exponents against an independent high-precision oracle.
for seconds in range(1800):
    score = MAX * X32
    actual = decay(score, seconds)
    exact = Decimal(score) * Decimal(2) ** (-Decimal(seconds) / 1800)
    assert Decimal(actual) > exact - 1
    assert Decimal(actual) - exact < Decimal(score) * 3600 / X64

# Frequent checkpoints carry bounded rounding error. This is an arithmetic probe;
# the contract permits checkpoints only with positive swaps (and adds principal).
start = 1000 * X32
frequent = start
for _ in range(1800):
    frequent = decay(frequent, 1)
assert abs(frequent - decay(start, 1800)) < 1800
output = dict(units="Quote atoms; score is Quote atoms times 2^32", decay_second_x64=str(BASE), fee_vectors=fee_rows,
              decay_vectors=decay_rows, cadence_probe=dict(start_x32=str(start), one_second_checkpoints=1800,
              frequent_x32=str(frequent), single_x32=str(decay(start, 1800)), absolute_difference_x32=str(abs(frequent-decay(start,1800)))))
Path(__file__).with_name('dex-fees.json').write_text(json.dumps(output, indent=2) + '\n')
print('Generated dex-fees.json; all 1800 fractional decay exponents and cadence bounds passed.')
