"""Research reference, not contract arithmetic or a historical backtest.

Run with python3 docs/research/volume-fee-model.py. Uses exact rational fee
math; exponential decay uses floating point only for illustrative scenarios.
"""

from fractions import Fraction as F
from decimal import Decimal, localcontext
from math import exp2, log
from random import Random
import json

# User-selected Meme-pool fee bounds, 2026-09-05. K and H remain examples.
BASE = F(0)
CAP = F(200, 10_000)
TARGET = 100_000
HALF_LIFE_HOURS = F(1, 2)


def potential(v, target=TARGET):
    v = F(v)
    ramp = v * v / (2 * target) if v <= target else v - F(target, 2)
    return BASE * v + (CAP - BASE) * ramp


def charge(v, q, target=TARGET):
    return potential(v + q, target) - potential(v, target)


def marginal(v, target=TARGET):
    return BASE + (CAP - BASE) * min(F(v, target), 1)


def ceil_fraction(x):
    return (x.numerator + x.denominator - 1) // x.denominator


def buy_principal(v, gross):
    """Largest integer reserve contribution covered by the gross Quote input."""
    lo, hi = 0, gross
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if mid + ceil_fraction(charge(v, mid)) <= gross:
            lo = mid
        else:
            hi = mid - 1
    return lo


def analytic_buy_principal(v, gross):
    """High-precision real root, independently compared with integer search."""
    if v >= TARGET:
        return int(F(gross) / (1 + CAP))
    to_cap = TARGET - v
    budget_to_cap = to_cap + charge(v, to_cap)
    if gross >= budget_to_cap:
        return int(to_cap + (gross - budget_to_cap) / (1 + CAP))
    with localcontext() as context:
        context.prec = 80
        decimal = lambda value: Decimal(value.numerator) / Decimal(value.denominator)
        a = decimal((CAP - BASE) / (2 * TARGET))
        b = decimal(1 + BASE + (CAP - BASE) * F(v, TARGET))
        # Rationalized quadratic root avoids subtracting nearly equal terms.
        return int(2 * Decimal(gross) / (b + (b*b + 4*a*gross).sqrt()))


def verify():
    rng = Random(20260905)
    for _ in range(2000):
        v = rng.randrange(0, 3 * TARGET)
        q1, q2 = rng.randrange(1, 2 * TARGET), rng.randrange(1, 2 * TARGET)
        whole = charge(v, q1 + q2)
        split = charge(v, q1) + charge(v + q1, q2)
        assert split == whole
        # A separately chosen bounded-memory policy also composes at one time,
        # because the marginal rate is constant above the target.
        v_bounded = min(v, TARGET)
        assert charge(v_bounded, q1) + charge(min(TARGET, v_bounded + q1), q2) == charge(v_bounded, q1 + q2)
        assert BASE * (q1 + q2) <= whole <= CAP * (q1 + q2)
        assert marginal(v) <= marginal(v + q1)
        rounding_delta = ceil_fraction(charge(v, q1)) + ceil_fraction(charge(v + q1, q2)) - ceil_fraction(whole)
        assert 0 <= rounding_delta <= 1
        gross = rng.randrange(1, 4 * TARGET)
        principal = buy_principal(v, gross)
        assert principal == analytic_buy_principal(v, gross)
        assert principal + ceil_fraction(charge(v, principal)) <= gross
        assert principal + 1 + ceil_fraction(charge(v, principal + 1)) > gross

        # Exact real-arithmetic V2 conservation with Quote fees outside reserves.
        meme, quote = F(1_000_000), F(100_000)
        invariant = meme * quote
        paid_fee = charge(v, q1)
        meme_out = meme * q1 / (quote + q1)
        assert (meme - meme_out) * (quote + q1) == invariant
        opening_trader_quote = F(q1) + paid_fee
        assert quote + opening_trader_quote == (quote + q1) + paid_fee
        meme_after_first = meme - meme_out
        meme_out_second = meme_after_first * q2 / (quote + q1 + q2)
        assert meme_out + meme_out_second == meme * (q1 + q2) / (quote + q1 + q2)
        # A buy followed by a sell of exactly the purchased Meme restores
        # reserves when burn is disabled: price impact is not an extra loss.
        quote_back = (quote + q1) * meme_out / (meme_after_first + meme_out)
        assert quote_back == q1
        round_trip_fee = paid_fee + charge(v + q1, quote_back)
        assert round_trip_fee == charge(v, 2 * q1)
        ending_trader_quote = quote_back - charge(v + q1, quote_back)
        assert opening_trader_quote - ending_trader_quote == round_trip_fee
        # Sell settlement uses the same upward-rounded Quote charge.
        sell_fee = ceil_fraction(charge(v, q1))
        sell_receipt = q1 - sell_fee
        assert sell_receipt >= 0
        assert F(q1) == sell_receipt + sell_fee
        assert sell_fee >= charge(v, q1)
        assert sell_fee - charge(v, q1) < 1

    assert charge(0, TARGET) == F(1000)
    assert charge(0, TARGET) == sum(charge(i * 1000, 1000) for i in range(100))
    # Pretrade-only pricing undercharges the unsplit trade in this example.
    assert BASE * TARGET == 0
    assert sum(marginal(i * 1000) * 1000 for i in range(100)) == F(990)
    # A zero marginal floor does not make a finite first trade free.
    assert charge(0, 1000) == F(1, 10)
    # This dust sell must be rejected by a zero-output guard.
    assert 1 - ceil_fraction(charge(0, 1)) == 0


def scenarios():
    rate = float(log(2) / float(HALF_LIFE_HOURS))
    return {
        "status": "2000 exact randomized scenarios passed; not Move verification",
        "selected_fee_bounds_and_illustrative_scale": {"base_bps": 0, "cap_bps": 200, "target_quote": TARGET, "half_life_minutes": 30},
        "marginal_fee_bps_by_volume_fraction": {str(x): float(marginal(F(x) * TARGET) * 10_000) for x in [0, .25, .5, .75, 1]},
        "instant_burst_to_target_gross_quote_fees": float(charge(0, TARGET)),
        "pretrade_only_one_trade_fee": float(BASE * TARGET),
        "pretrade_only_100_trade_fee": float(sum(marginal(i * 1000) * 1000 for i in range(100))),
        "integrated_one_or_100_trade_fee": float(charge(0, TARGET)),
        "idle_fee_bps_from_target": {str(minutes): float((BASE + (CAP-BASE) * F(exp2(-minutes / 30))) * 10_000) for minutes in [0, 15, 30, 60, 120]},
        "fluid_volume_per_hour_to_sustain_target": TARGET * rate,
        "fluid_gross_fee_per_hour_to_sustain_target": float(CAP) * TARGET * rate,
        "fluid_net_fee_per_hour_if_80_percent_recaptured": .2 * float(CAP) * TARGET * rate,
    }


def verify_admin_caps():
    """Parameter-change and zero-cap boundary checks for the research model."""
    global CAP
    selected_cap = CAP
    try:
        for cap in [F(0), F(20, 10_000), F(200, 10_000), F(300, 10_000), F(500, 10_000)]:
            CAP = cap
            for v in [0, 1, 50_000, 99_999, 100_000, 200_000]:
                for gross in [1, 2, 999, 1000, 100_001, 2**64 - 1]:
                    q = buy_principal(v, gross)
                    assert q == analytic_buy_principal(v, gross)
                    assert q + ceil_fraction(charge(v, q)) <= gross
        CAP = F(200, 10_000)
        old_fee = charge(50_000, 1000)
        CAP = F(500, 10_000)
        new_fee = charge(50_000, 1000)
        assert old_fee == F(101, 10) and new_fee == F(101, 4)
        # An actual rounded fee limit, with Quote principal as denominator.
        assert ceil_fraction(old_fee) * 10_000 <= 200 * 1000
        assert ceil_fraction(new_fee) * 10_000 > 200 * 1000
    finally:
        CAP = selected_cap


if __name__ == "__main__":
    verify()
    verify_admin_caps()
    print(json.dumps(scenarios(), indent=2))
