#!/usr/bin/env python3
"""Regenerate curve.json and quote-decimals.json from the formulas that own them.

Buys follow curve::cap_buy_quote_input then curve::quote_buy (ADRs 0021, 0039, 0043), sells follow
curve::quote_sell (ADRs 0021, 0077), and the terminal disposition follows ADR 0039. The migration
prices in quote-decimals.json (ADR 0005) start from the terminal state that the threshold-crossing
buy reaches, so both files are written together.
"""
from decimal import ROUND_HALF_EVEN, Decimal, localcontext
from fractions import Fraction
from math import isqrt
import json
from pathlib import Path

BPS = 10_000
MEME_TOTAL_SUPPLY = 1_000_000_000_000_000_000
M0 = 800_000_000_000_000_000
V = 1_000_000_000_000
T = 3_000_000_000_000
QUOTE_FEE_BPS = 100
MEME_FEE_BPS = 0
SELL_BURN_BPS = 100
MIGRATION_FEE_BPS = 100
MIGRATION_FEE_CEILING_BPS = 300
MIN_SQRT_PRICE_X64 = 4_295_048_016
MAX_SQRT_PRICE_X64 = 79_226_673_515_401_279_992_447_579_055
DISPLAY_DECIMAL_PLACES = 34


def ceil_div(numerator, denominator):
    return -(-numerator // denominator)


def buy(meme_reserve, real_quote, quote_supplied, quote_fee_bps=QUOTE_FEE_BPS, meme_fee_bps=MEME_FEE_BPS, virtual_quote=V, terminal_threshold=T):
    """curve::cap_buy_quote_input, then curve::quote_buy and the reserve movement launch.move applies."""
    if quote_supplied - ceil_div(quote_supplied * quote_fee_bps, BPS) <= terminal_threshold - real_quote:
        quote_in_gross = quote_supplied
    else:
        quote_in_gross = ceil_div((terminal_threshold - real_quote) * BPS, BPS - quote_fee_bps)
    quote_fee = ceil_div(quote_in_gross * quote_fee_bps, BPS)
    quote_in_net = quote_in_gross - quote_fee
    meme_out_gross = meme_reserve * quote_in_net // (virtual_quote + real_quote + quote_in_net)
    meme_fee = ceil_div(meme_out_gross * meme_fee_bps, BPS)
    return {
        "quote_in_gross": quote_in_gross,
        "quote_refund": quote_supplied - quote_in_gross,
        "quote_fee": quote_fee,
        "quote_in_net": quote_in_net,
        "meme_out_gross": meme_out_gross,
        "meme_fee": meme_fee,
        "meme_out_net": meme_out_gross - meme_fee,
        "meme_reserve_after": meme_reserve - meme_out_gross,
        "real_quote_after": real_quote + quote_in_net,
        "crossed_threshold": real_quote + quote_in_net >= terminal_threshold,
    }


def sell(
    meme_reserve,
    real_quote,
    meme_in,
    virtual_quote=V,
    terminal_threshold=T,
    quote_fee_bps=QUOTE_FEE_BPS,
    meme_fee_bps=MEME_FEE_BPS,
    sell_burn_bps=SELL_BURN_BPS,
):
    """curve::quote_sell and the reserve movement launch.move applies."""
    meme_fee = ceil_div(meme_in * meme_fee_bps, BPS)
    meme_in_after_fee = meme_in - meme_fee
    meme_pending_burn = ceil_div(meme_in_after_fee * sell_burn_bps, BPS)
    meme_in_effective = meme_in_after_fee - meme_pending_burn
    quote_out_gross = (virtual_quote + real_quote) * meme_in_effective // (meme_reserve + meme_in_effective)
    quote_fee = ceil_div(quote_out_gross * quote_fee_bps, BPS)
    return {
        "meme_fee": meme_fee,
        "meme_in_after_fee": meme_in_after_fee,
        "progress_bps": min(real_quote * BPS // terminal_threshold, BPS),
        "burn_bps": sell_burn_bps,
        "meme_pending_burn": meme_pending_burn,
        "meme_in_effective": meme_in_effective,
        "quote_out_gross": quote_out_gross,
        "quote_fee": quote_fee,
        "quote_out_net": quote_out_gross - quote_fee,
        "meme_reserve_after": meme_reserve + meme_in_effective,
        "real_quote_after": real_quote - quote_out_gross,
        "clamp_would_bind": quote_out_gross > real_quote,
    }


def after(trade):
    """The reserve state a trade leaves, as the next case's given."""
    return {"meme_reserve": trade["meme_reserve_after"], "real_quote": trade["real_quote_after"]}


def case(name, kind, given, expect, notes):
    return {"name": name, "kind": kind, "given": given, "expect": expect, "notes": notes}


def buy_case(name, given, notes):
    return case(name, "buy", given, buy(**given), notes)


def sell_case(name, given, notes, **extra):
    return case(name, "sell", given, sell(**given) | extra, notes)


def display_decimal(price):
    with localcontext() as context:
        context.prec = 100
        exact = Decimal(price.numerator) / Decimal(price.denominator)
        return str(exact.quantize(Decimal(1).scaleb(-DISPLAY_DECIMAL_PLACES), rounding=ROUND_HALF_EVEN))


def significant_digits_rounding_alike(a, b):
    """The most significant digits to which both prices round, half-even, to the same decimal."""
    digits = 0
    with localcontext() as context:
        while True:
            context.prec = digits + 1
            if Decimal(a.numerator) / Decimal(a.denominator) != Decimal(b.numerator) / Decimal(b.denominator):
                return digits
            digits += 1


def has_prime_factor_other_than_2_and_5(value):
    for prime in (2, 5):
        while value % prime == 0:
            value //= prime
    return value > 1


def price_case(name, meme_decimals, quote_decimals, meme_atomic, quote_atomic, notes):
    sqrt_a = isqrt((quote_atomic << 128) // meme_atomic)
    sqrt_b = isqrt((meme_atomic << 128) // quote_atomic)
    price = Fraction(quote_atomic, 10**quote_decimals) / Fraction(meme_atomic, 10**meme_decimals)
    record = {
        "name": name,
        "given": {
            "meme_decimals": meme_decimals,
            "quote_decimals": quote_decimals,
            "meme_atomic": meme_atomic,
            "quote_atomic": quote_atomic,
        },
        "expect": {
            "sqrt_price_x64_meme_is_coin_a": sqrt_a,
            "sqrt_price_x64_meme_is_coin_b": sqrt_b,
            "both_in_venue_range": all(MIN_SQRT_PRICE_X64 < s < MAX_SQRT_PRICE_X64 for s in (sqrt_a, sqrt_b)),
            "display_factor_exponent": meme_decimals - quote_decimals,
            "display_price_quote_per_meme_exact_rational": f"{price.numerator}/{price.denominator}",
            "display_price_quote_per_meme_decimal_34sf": display_decimal(price),
            "display_price_is_a_derived_presentation_value": True,
        },
        "notes": notes,
    }
    return record, price


# === curve.json ===

first = buy_case(
    "buy_first_one_quote_unit",
    {"meme_reserve": M0, "real_quote": 0, "quote_supplied": 1_000_000_000},
    "Opening trade against virtual liquidity only.",
)
mid = buy_case(
    "buy_mid",
    after(first["expect"]) | {"quote_supplied": 500_000_000_000},
    "Continues from buy_first_one_quote_unit.",
)
below = buy_case(
    "buy_to_below_threshold",
    {"meme_reserve": M0, "real_quote": 0, "quote_supplied": 2_500_000_000_000},
    "Fresh sequence. Stops just below the terminal threshold.",
)
crossing = buy_case(
    "buy_crossing_threshold",
    after(below["expect"]) | {"quote_supplied": 600_000_000_000},
    "Continues from buy_to_below_threshold. The supplied Quote would carry the reserve past T, so the "
    "buy charges only ceil((T - Q) * 10000 / (10000 - quote_fee_bps)), the smallest gross input whose "
    "post-fee Quote reaches T exactly, and refunds the rest; the refund never enters the curve, the fees, "
    "or migration principal. Crossing happens on a buy only. The terminal state feeds the migration price.",
)
terminal = crossing["expect"]
live_edge = buy(M0, 0, T - 1, quote_fee_bps=0)
migration_fee = ceil_div(terminal["real_quote_after"] * MIGRATION_FEE_BPS, BPS)
disposition = case(
    "terminal_disposition",
    "migration",
    after(terminal) | {"migration_fee_bps": MIGRATION_FEE_BPS},
    {
        "migration_fee": migration_fee,
        "quote_to_liquidity": terminal["real_quote_after"] - migration_fee,
        "meme_available_for_liquidity": terminal["meme_reserve_after"],
        "burn_moment_2_rule": "meme_available_for_liquidity minus meme actually deployed by the venue adapter is burned in one accounted step before the supply state is locked to BurnOnly",
    },
    "Burn moment 2. The capped crossing leaves the real Quote reserve at exactly T, so the fee is ADR 0039's "
    "ceil(T * F / 10000). The exact burned amount depends on how much meme the venue consumes at the "
    "derived price, so the rule is asserted rather than a fixed number.",
)

assert not below["expect"]["crossed_threshold"] and below["expect"]["quote_refund"] == 0
assert crossing["expect"]["quote_refund"] > 0 and terminal["real_quote_after"] == T
assert live_edge["real_quote_after"] == T - 1

one_unit = buy(M0, 0, 1)
oversell = sell(M0, 0, 1_000_000_000)

curve = {
    "schema_version": 3,
    "description": "Constant-product bonding curve with virtual quote liquidity: buys, sells, creator-selected fixed sell-side burn, terminal disposition burn, a threshold crossing capped at the graduation target with its excess Quote refunded, and boundary cases.",
    "source_decisions": [
        "docs/decisions/0021-pure-constant-product-curve-quotes.md",
        "docs/decisions/0026-deferred-sell-burn.md",
        "docs/decisions/0039-deterministic-quote-valuations.md",
        "docs/decisions/0041-launch-config-owned-trade-fees.md",
        "docs/decisions/0043-versioned-launch-trading-and-atomic-migration.md",
        "docs/decisions/0006-fees-and-launch-paths.md",
        "docs/decisions/0077-fixed-creator-selected-sell-burn.md",
    ],
    "status": "proposed",
    "units": {
        "meme": "atomic units, 9 decimals in these cases",
        "quote": "atomic units, 9 decimals in these cases",
        "bps": "basis points, 10000 = 100%",
        "rounding": {
            "quote_in_gross": "ceil - when T caps a buy, the smallest gross input whose post-fee Quote reaches T exactly",
            "quote_refund": "the supplied Quote above quote_in_gross, returned whole to the buyer",
            "meme_out_gross": "floor - curve payout rounds down",
            "meme_fee": "ceil - protocol fee rounds up",
            "meme_out_net": "gross meme output minus meme fee",
            "quote_out_gross": "floor - user payout rounds down",
            "quote_fee": "ceil - protocol fee rounds up",
            "progress_bps": "floor - never overstates progress",
            "burn_bps": "the immutable creator-selected rate applied to post-fee Meme input",
            "meme_pending_burn": "ceil - seller obligation rounds up",
            "migration_fee": "ceil - protocol fee rounds up",
        },
    },
    "parameters": {
        "note": "Deployment values remain proposed. The fixed sell-burn formula and hard 5,000 bps creator ceiling are accepted by docs/decisions/0077-fixed-creator-selected-sell-burn.md. Changing an economic input invalidates every affected case below; regenerate with python3 docs/vectors/generate_curve.py.",
        "meme_total_supply_atomic": MEME_TOTAL_SUPPLY,
        "curve_meme_inventory_M0_atomic": M0,
        "virtual_quote_V_atomic": V,
        "terminal_threshold_T_atomic": T,
        "quote_fee_bps": QUOTE_FEE_BPS,
        "meme_fee_bps": MEME_FEE_BPS,
        "sell_burn_bps": SELL_BURN_BPS,
        "migration_fee_bps": MIGRATION_FEE_BPS,
        "migration_fee_ceiling_bps": MIGRATION_FEE_CEILING_BPS,
    },
    "formulas": {
        "buy": "q=quote_supplied; q_gross=q if q-ceil(q*quote_fee_bps/10000)<=T-Q else ceil((T-Q)*10000/(10000-quote_fee_bps)); quote_refund=q-q_gross; quote_fee=ceil(q_gross*quote_fee_bps/10000); q_net=q_gross-quote_fee; meme_gross=floor(M*q_net/(V+Q+q_net)); meme_fee=ceil(meme_gross*meme_fee_bps/10000); meme_net=meme_gross-meme_fee; M'=M-meme_gross; Q'=Q+q_net; crossed_threshold=Q'>=T",
        "sell": "meme_fee=ceil(m*meme_fee_bps/10000); m_after_fee=m-meme_fee; progress_bps=min(floor(Q*10000/T),10000) as telemetry; burn_bps=sell_burn_bps; burned=ceil(m_after_fee*burn_bps/10000); eff=m_after_fee-burned; gross=floor((V+Q)*eff/(M+eff)); quote_fee=ceil(gross*quote_fee_bps/10000); net=gross-quote_fee; M'=M+eff; Q'=Q-gross",
        "migration": "migration_fee=ceil(Q*migration_fee_bps/10000); quote_to_liquidity=Q-migration_fee",
    },
    "cases": [
        first,
        buy_case(
            "buy_meme_fee_only",
            {"meme_reserve": M0, "real_quote": 0, "quote_supplied": 1_000_000_000, "quote_fee_bps": 0, "meme_fee_bps": 100},
            "A zero quote rate and positive meme rate select meme-only fees.",
        ),
        buy_case(
            "buy_both_asset_fees",
            {"meme_reserve": M0, "real_quote": 0, "quote_supplied": 1_000_000_000, "quote_fee_bps": 100, "meme_fee_bps": 100},
            "Positive rates in both assets charge each fee exactly once.",
        ),
        mid,
        sell_case(
            "sell_mid_with_fixed_burn",
            after(mid["expect"]) | {"meme_in": 1_000_000_000_000_000},
            "The creator-selected 100 bps rate applies unchanged at partial progress. quote_out_gross <= real_quote holds without a clamp.",
        ),
        sell_case(
            "sell_both_asset_fees",
            after(mid["expect"]) | {"meme_in": 1_000_000_000_000_000, "quote_fee_bps": 100, "meme_fee_bps": 100},
            "Meme fee precedes the burn and curve; quote fee follows the curve.",
        ),
        sell_case(
            "sell_max_burn_after_meme_fee",
            {
                "meme_reserve": 1000,
                "real_quote": 500,
                "virtual_quote": 1000,
                "terminal_threshold": 1000,
                "meme_in": 1000,
                "quote_fee_bps": 0,
                "meme_fee_bps": 100,
                "sell_burn_bps": 5000,
            },
            "A gross Meme input of 1000 pays the 1% Meme fee first, then reserves 50% of the remaining 990 for burn, so the curve prices 495.",
        ),
        *[
            buy_case(
                f"terminal_dust_{gross_meme}_gross_meme",
                after(buy(
                    725_000_000_000_000_000, 0,
                    ceil_div((target - 1) * BPS, BPS - 100),
                    meme_fee_bps=250, virtual_quote=target, terminal_threshold=target,
                )) | {
                    "quote_supplied": 100, "quote_fee_bps": 100, "meme_fee_bps": 250,
                    "virtual_quote": target, "terminal_threshold": target,
                },
                "Reachable after an ordinary buy to target minus one. With minimum Meme zero, "
                "the final buy charges two Quote atoms, credits one to reserves and one to fees, "
                "refunds 98, and graduates even when net Meme is zero (Asymptotic L-2).",
            )
            for target, gross_meme in [(10**18, 0), (10**17, 1)]
        ],
        below,
        crossing,
        sell_case(
            "sell_at_full_progress_unreachable",
            after(terminal) | {"meme_in": 1_000_000_000_000_000},
            "Pure-math boundary, UNREACHABLE through the lifecycle. progress_bps reaches 10000 only at real_quote = T, and the capped crossing buy that reaches T closes trading. The fixed burn remains 100 bps; progress is telemetry only.",
            abort="EUnreachableByConstruction",
        ),
        sell_case(
            "sell_at_max_live_progress",
            after(live_edge) | {"meme_in": 1_000_000_000_000_000},
            "At real_quote = T-1, the state a fee-free buy of T-1 Quote leaves, progress telemetry is 9999 while the creator-selected burn remains exactly 100 bps.",
        ),
        sell_case(
            "sell_round_trip_immediately_after_first_buy",
            after(first["expect"]) | {"meme_in": first["expect"]["meme_out_net"]},
            "The fixed 100 bps burn applies immediately after the opening buy; progress_bps is informational and does not scale it.",
        ),
        case(
            "buy_one_atomic_unit",
            "buy",
            {"meme_reserve": M0, "real_quote": 0, "quote_supplied": 1},
            {
                "abort": "EZeroOutput",
                "quote_fee": one_unit["quote_fee"],
                "quote_in_net": one_unit["quote_in_net"],
                "meme_out_gross_if_unguarded": one_unit["meme_out_gross"],
            },
            "One atomic quote unit is entirely consumed by the ceiling fee. A zero-output trade must abort with a named error, not succeed silently.",
        ),
        case(
            "sell_more_meme_than_exists_outside_curve",
            "sell",
            {"meme_reserve": M0, "real_quote": 0, "meme_in": 1_000_000_000},
            {
                "abort": "EUnreachableByConstruction",
                "quote_out_gross_if_unguarded": oversell["quote_out_gross"],
                "real_quote_available": 0,
            },
            "Unreachable in practice: no meme exists outside the curve at M0, so no caller can hold this Coin<Meme>. Recorded because it is exactly the state in which the historical .min() clamp would bind. Blast asserts the sell-back invariant instead of clamping.",
        ),
        disposition,
    ],
    "properties": [
        {
            "name": "sell_back_invariant",
            "statement": "For any gross meme input not exceeding the user's net meme received from reachable buys, quote_out_gross <= real_quote.",
            "status": "backed by sui/launchpad/tests/curve_tests.move at fixed seed 314159 over 256 reachable buy-then-sell scenarios cycling through no fees, quote-only, meme-only, and both",
            "evidence": "Every scenario sells the complete purchased Meme amount and one generated partial amount. The test commits its generator, fee modes, parameters, seed, operation count, an algebraically equivalent pre-call check, and an assert_eq trace that prints the operation index plus all generated/state inputs on failure.",
        },
        {
            "name": "monotonicity",
            "statement": "At fixed fee rates, meme_out_net is non-decreasing in quote_in and non-increasing in real_quote.",
        },
        {
            "name": "conservation_meme_atomic_units",
            "statement": "before migration: meme_total_supply_initial = M + meme_outstanding + accrued_fees_meme + meme_named_claims + pending_burn + meme_deployed_to_venue; after migration pending_burn becomes burned_terminal",
            "note": "Burn appears only in this identity. Meme and quote are never combined into one equation.",
        },
        {
            "name": "conservation_quote_atomic_units",
            "statement": "quote_in_total = quote_out_total + Q + accrued_fees_quote + quote_named_claims + migration_fee_quote + quote_deployed_to_venue",
            "note": "quote_in_total sums each buy's quote_in_gross; a capped buy's quote_refund never enters it.",
        },
        {
            "name": "sell_burn_is_progress_independent",
            "statement": "For every executable sell, burn_bps equals the immutable creator-selected sell_burn_bps; progress_bps is telemetry and does not change the burn rate.",
        },
        {
            "name": "intermediate_width",
            "statement": "All products and effective-reserve sums widen to u256. Buy output is bounded by M; sell output is at most Q in every reachable state (sell_back_invariant), and the real-reserve split aborts otherwise; post-trade u64 reserve additions are checked.",
        },
    ],
}

# === quote-decimals.json ===

meme_atomic = disposition["expect"]["meme_available_for_liquidity"]
quote_atomic = disposition["expect"]["quote_to_liquidity"]
truncated_meme_atomic = meme_atomic // 1000
assert meme_atomic % 1000 != 0, "the six-decimal case must be a truncated, different reserve state"
assert quote_atomic % 1000 == 0, "the quote rescalings must be exact"

sui_like, shared_price = price_case(
    "sui_like_9dec_quote",
    9,
    9,
    meme_atomic,
    quote_atomic,
    "MEME/SUI. Raw ratio and display price coincide only because the decimals are equal.",
)
usdc_like, usdc_price = price_case(
    "usdc_like_6dec_quote",
    9,
    6,
    meme_atomic,
    quote_atomic // 1000,
    "MEME/USDC. Raw ratio is 1000x smaller than the 9-decimal case, yet the display price is identical.",
)
lst_like, lst_price = price_case(
    "lst_like_8dec_quote",
    9,
    8,
    meme_atomic,
    quote_atomic // 10,
    "MEME/sSUI-style liquid staking token at 8 decimals.",
)
six_decimal_meme, six_decimal_price = price_case(
    "meme_6dec_quote_9dec",
    6,
    9,
    truncated_meme_atomic,
    quote_atomic,
    "Non-9-decimal meme. Present specifically so no formula may depend on the meme having 9 decimals.",
)
assert shared_price == usdc_price == lst_price != six_decimal_price
assert has_prime_factor_other_than_2_and_5(shared_price.denominator)

shared_rational = f"{shared_price.numerator}/{shared_price.denominator}"
quote_decimals = {
    "schema_version": 1,
    "description": "Migration price derivation across quote decimal combinations and both pair orientations. Demonstrates that the on-chain raw-ratio calculation needs no decimal correction, while the human display price needs both decimal values.",
    "source_decisions": [
        "docs/decisions/0005-quote-asset-generalisation.md",
        "docs/decisions/0010-migration-and-venue-adapters.md",
    ],
    "status": "proposed",
    "units": {
        "meme_atomic": "meme atomic units at meme_decimals",
        "quote_atomic": "quote atomic units at quote_decimals",
        "sqrt_price_x64": "Q64.64 fixed point, the Uniswap-V3 convention used by all three target venues",
    },
    "venue_bounds": {
        "min_sqrt_price_x64": MIN_SQRT_PRICE_X64,
        "max_sqrt_price_x64": MAX_SQRT_PRICE_X64,
        "tick_bound": 443636,
        "evidence": [
            "CetusProtocol/cetus-contracts@ddfbdeba174319998b012de876ab7ec23c3ab0bc:packages/cetus_clmm/sources/math/tick_math.move:7-11",
            "turbos-finance/turbos-sui-move-interface@cff693265bfc41c7de2233afe31c9d7428adc9e1:clmm/sources/lib/math_tick.move:12-14",
        ],
    },
    "formulas": {
        "meme_is_coin_a": "sqrt_price_x64 = isqrt((quote_atomic << 128) / meme_atomic)",
        "meme_is_coin_b": "sqrt_price_x64 = isqrt((meme_atomic << 128) / quote_atomic)",
        "display_price": "display_price_quote_per_meme = raw_ratio * 10^(meme_decimals - quote_decimals)",
        "orientation_rule": "Cetus enforces a canonical order over defining-id type-name bytes, and the meme type name embeds an unpredictable freshly published package address, so the adapter must handle both orientations. Evidence: CetusProtocol/cetus-contracts@ddfbdeba174319998b012de876ab7ec23c3ab0bc:packages/cetus_clmm/sources/factory.move:1074-1140",
    },
    "cases": [sui_like, usdc_like, lst_like, six_decimal_meme],
    "properties": [
        {
            "name": "no_decimal_correction_on_chain",
            "statement": f"For a FIXED reserve state, changing the quote's decimals scales the raw atomic ratio by exactly 10^(meme_decimals - quote_decimals) and leaves the display price EXACTLY unchanged. Cases sui_like_9dec_quote, usdc_like_6dec_quote and lst_like_8dec_quote share the identical exact rational {shared_rational}, which is the proof. The on-chain raw-ratio calculation therefore applies no decimal correction; only the display conversion does.",
            "caveat": f"meme_6dec_quote_9dec is a DIFFERENT reserve state, not a rescaling: a 6-decimal token cannot represent {meme_atomic} nine-decimal atomic units, so its meme reserve is truncated to {truncated_meme_atomic}. Its exact display price {six_decimal_price.numerator}/{six_decimal_price.denominator} therefore differs from the other three, and the two round alike only to {significant_digits_rounding_alike(shared_price, six_decimal_price)} significant digits. Stating this prevents the false claim that all four are exactly equal.",
            "reproduce": "display = Fraction(quote_atomic, 10**quote_decimals) / Fraction(meme_atomic, 10**meme_decimals)",
        },
        {
            "name": "both_orientations_covered",
            "statement": "Every case supplies the sqrt price for the meme as coin A and as coin B. The adapter must select by the venue's canonical ordering, not by assumption.",
        },
        {
            "name": "range_guard",
            "statement": "Every derived sqrt_price_x64 lies strictly inside [min_sqrt_price_x64, max_sqrt_price_x64]. A derived price outside the range must abort rather than clamp.",
        },
        {
            "name": "pair_immutability",
            "statement": "The (Meme, Quote) pair used to derive these values is fixed at launch and identical at migration. No route, retry, or recovery path may change it.",
        },
        {
            "name": "display_price_is_not_terminating",
            "statement": f"The exact display price the three nine-decimal-meme cases share is a non-terminating rational: {shared_price.denominator} has prime factors other than 2 and 5. Any decimal rendering is therefore a rounded presentation value, never the exact quantity. The exact rational is authoritative; the decimal rounded to 34 places is provided for human comparison only and must not be used as a test oracle.",
        },
    ],
}

directory = Path(__file__).parent
for name, document in (("curve.json", curve), ("quote-decimals.json", quote_decimals)):
    (directory / name).write_text(json.dumps(document, indent=2) + "\n")
print("Generated curve.json and quote-decimals.json.")
