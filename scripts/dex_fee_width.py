"""Exact rational error budget for the source-pinned Q96 fee quote."""
from fractions import Fraction as F
from math import ceil

Q = 1 << 96
ULP = F(1, Q)


def mul_width(left, right, left_max, right_max):
    # Product endpoint difference, plus outward rounding at both ends.
    return ceil(right_max * left + left_max * right + 2)


def div_width(num, den, den_min, exact_quotient_max):
    # The unrounded lower quotient is at most the exact quotient.
    bottom = den_min - den * ULP
    assert bottom > 0
    return ceil((num + exact_quotient_max * den) / bottom + 2)


def sqrt_width(width, radicand_min, root_min):
    # Use an endpoint lower bound in the denominator of sqrt(h) - sqrt(l).
    assert root_min > 0 and root_min**2 <= radicand_min - width * ULP
    return ceil(F(width, 2) / root_min + 2)


def cap_and_pole_widths():
    # The ppm fractions each have width at most one. In the dynamic
    # branch, cap exceeds base by at least one ppm and base is positive.
    gap_squared = div_width(1, 1, F(1, 10), 1)
    gap_small = sqrt_width(gap_squared, F(1, 10**8), F(1, 11_000))
    gap_large = sqrt_width(gap_squared, F(1, 4), F(49, 100))
    lower_cap = max(
        sqrt_width(gap_small, F(1, 2), F(7, 10)),
        sqrt_width(gap_large, F(1, 200_000), F(1, 500)),
    )
    upper_cap = sqrt_width(max(gap_small, gap_large), F(1), F(99, 100))
    pole_squared = div_width(1, 1, F(1, 10), 10)
    pole = sqrt_width(pole_squared, F(9, 1000), F(9, 100))
    # k*(1-b) <= 100. Its rounded endpoints fit under 101.
    product = mul_width(1, 1, 101, 1)
    prefactor_den = 2 * sqrt_width(product, F(9, 100), F(29, 100))
    prefactor = div_width(0, prefactor_den, F(3, 5), F(5, 3))
    return max(lower_cap, upper_cap), pole, prefactor


def analytic_width(pole, prefactor):
    # Reciprocal price endpoints have width 1 and t <= sqrt(2).
    # p <= 2, delta <= 1, d >= (17/25)*sqrt(.9/100) > 1/16.
    product = mul_width(1, 1, F(3, 2), F(3, 2))
    delta_squared = mul_width(2, 2, F(1) + 2 * ULP, F(1) + 2 * ULP)
    product_delta_squared = mul_width(product, delta_squared, F(2) + product * ULP,
                                     F(1) + delta_squared * ULP)
    denominator = pole + product
    # Both rounded denominators are below 5 and above 1/16. The true
    # lower bound 17/25 * .094 is strong enough for the latter.
    assert F(17, 25) * F(94, 1000) - denominator * ULP > F(1, 16)
    assert F(21, 5) + denominator * ULP < 5
    denominator_squared = mul_width(denominator, denominator, 5, 5)
    numerator = mul_width(pole, delta_squared, 5, F(1) + delta_squared * ULP)
    argument = div_width(numerator, denominator_squared, F(1, 256), F(49, 100))
    midpoint_max = F(491, 1000)
    assert F(49, 100) + argument * ULP < midpoint_max < F(1, 2)

    # The 65-term cap reaches index 64. At an earlier exit power is zero.
    # The first omitted power can acquire at most 2*m+1 units of padding.
    # The two successive ceilings add less than two units to the tail.
    tail = ceil((Q * midpoint_max**65 + 2 * midpoint_max + 1)
                / ((1 - midpoint_max) * 131) + 2)
    tail = max(tail, 3)
    regular_series = 2 * (3 * 65 + tail + 2 * argument)
    # If z's enclosure straddles zero, true |z| <= pole width. The code
    # pads S(0) by twice the upper bound on |z|*delta^2/d^2.
    straddled_series = 1 + 4 * (256 * pole + argument)
    series = max(regular_series, straddled_series)
    assert F(1, 1 - midpoint_max) + series * ULP < 2
    assert F(1, 3) / (1 - midpoint_max) + series * ULP < 1

    # F/d <= 1/(2*(1-b)*(1-g/w)) < 5/6 before rounding. Hence F_hi/d_lo <= 1.
    assert F(1, 2) / (F(9, 10) * F(17, 25)) < F(5, 6)
    assert (prefactor + denominator) * ULP < F(1, 96)
    assert F(5, 3) + prefactor * ULP < 2
    gain_width = 16 * (prefactor + denominator)
    upward = 2 * (series + 2 * gain_width) + 10

    # Let C be the rounded d^3 interval. Each endpoint incurs <6 ulps
    # from its squared and cubed products. Use relative width for C.
    assert F(1, 4096) - 6 * ULP > F(1, 5000)
    relative_cube = 48 * denominator + 12 * 5000
    # M = p*delta^2, delta/d <= 8/17. With F_hi <= d and
    # C_lo >= .9*d^3, the rounded gain F_hi*M_hi/C_lo is below 1.
    assert (48 * denominator + 6 * 4096) * ULP < F(1, 10)
    assert 2 * F(8, 17)**2 + 256 * product_delta_squared * ULP < F(9, 10)
    assert 2 + product_delta_squared * ULP < 3
    correction_gain = 5000 * (3 * prefactor + 2 * product_delta_squared) + relative_cube
    downward = 2 * (gain_width + series + correction_gain) + 40
    return max(upward, downward)


def average_width():
    cap, pole, prefactor = cap_and_pole_widths()
    analytic = analytic_width(pole, prefactor)
    # An endpoint inside the cap evaluates t, t^2, the absolute gap, and
    # gap squared. Reciprocal rounding gives the initial width of one.
    t_squared = mul_width(1, 1, F(3, 2), F(3, 2))
    gap_squared = mul_width(t_squared, t_squared, 2, 2)
    rate = 1 + mul_width(1, gap_squared, 101, 4)
    # Cap-edge pieces have diameter <= cap width + 8 in t, allowing for
    # reciprocal-rounded boundaries. Short pieces are bounded in x.
    rate_span = 45 * max(1024, cap + 8) + 2 * rate
    pointwise = div_width(rate_span, rate_span, F(9, 10), F(1, 9))
    capped = div_width(1, 1, F(9, 10), F(1, 9))
    segment = max(analytic, pointwise, capped)
    assert F(1, 9) + segment * ULP < 1
    # At most six pieces. Lower weights sum to at most one. Each product
    # adds two rounding ulps and at most one from the weight's width.
    return segment + 6 * 3 + 2 * 90


def prove_fee_width(prover):
    if not __debug__:
        raise SystemExit("Run the fee width certificate with Python assertions enabled.")
    prover.prove("admitted ppm lattice separates the nonconstant cap roots from singularities",
        "k base cap gap w",
        """
        (<= (/ 1 10) k) (<= k 100) (<= (/ 1 1000000) base)
        (<= (+ base (/ 1 1000000)) cap) (<= cap (/ 1 10))
        (>= gap 0) (> w 0) (= (* k gap gap) (- cap base)) (= (* k w w) (- 1 base))
        """,
        "(and (>= (* gap gap) (/ 1 100000000)) (<= gap (- 1 (/ 1 200000)))"
        " (>= (* w w) (/ 9 1000)) (<= (* w w) 10) (<= (* 25 gap) (* 8 w)))")
    prover.prove("rounded division width follows from denominator margin and exact quotient",
        "al ah bl bh l h exact max_exact",
        """
        (<= 0 al) (<= al ah) (< 0 bl) (<= bl bh)
        (= (* l bh) al) (= (* h bl) ah) (<= l exact) (<= exact max_exact)
        """,
        "(<= (* bl (- h l)) (+ (- ah al) (* max_exact (- bh bl))))")
    prover.prove("square root width follows from the endpoint lower bound",
        "lo hi root_lo root_hi root_min",
        """
        (< 0 root_min) (<= root_min root_lo) (<= root_lo root_hi)
        (= (* root_lo root_lo) lo) (= (* root_hi root_hi) hi)
        """,
        "(<= (* 2 root_min (- root_hi root_lo)) (- hi lo))")
    prover.prove("Newton relative error contracts at least quadratically above the root",
        "root y next rel",
        """
        (> root 0) (>= y root) (= y (* root (+ 1 rel)))
        (= (* 2 next y) (+ (* y y) (* root root)))
        """,
        "(and (>= next root) (<= (* 2 (- next root)) (* root rel rel)))")
    # A normalized radicand fits 200 bits. From a seed at most 2*sqrt(n),
    # eight Newton updates have error at most sqrt(n)*2^-255.
    assert F(1 << 100, 1 << (2**8 - 1)) < 1
    prover.prove("normalized Newton intermediates fit u256",
        "n y quotient",
        f"(<= 0 n) (< n {1 << 200}) (<= 1 y) (<= y {1 << 101})"
        " (<= 0 quotient) (<= (* y quotient) n)",
        f"(and (< (+ y quotient) {1 << 256}) (< (* y y) {1 << 256}))")
    prover.prove("reciprocal cap boundary rounding adds at most four price units",
        "x rounded t mapped",
        f"(>= x (/ 2 3)) (>= rounded (/ 2 3)) (<= (- x rounded) (/ 1 {Q}))"
        f" (<= (- rounded x) (/ 1 {Q})) (= (* x t) 1) (= (* rounded mapped) 1)",
        f"(and (<= (- mapped t) (/ 4 {Q})) (<= (- t mapped) (/ 4 {Q})))")
    prover.prove("segment weights add their errors without multiplying segment width by the cut count",
        "lo_w hi_w lo_s hi_s width upper",
        """
        (<= 0 lo_w) (<= lo_w hi_w) (<= 0 lo_s) (<= lo_s hi_s)
        (<= (- hi_s lo_s) width) (<= hi_s upper)
        """,
        "(<= (- (* hi_w hi_s) (* lo_w lo_s)) (+ (* lo_w width) (* upper (- hi_w lo_w))))")
    # The only wider intermediates are coordinate/weight shifts and the
    # final amount scaling, which have independent integer bounds.
    assert (1 << 17)**2 * Q**2 < 1 << 256
    assert ((1 << 64) - 1) * 100_000 * Q < 1 << 256
    prover.prove("admitted prices normalize below 224 bits in either direction",
        "price reference shifted normalized",
        f"""
        (<= {1 << 32} price) (< price {1 << 160})
        (<= {1 << 32} reference) (< reference {1 << 160})
        (= shifted (* price {Q})) (<= 0 normalized) (<= (* normalized reference) shifted)
        """,
        f"(and (< shifted {1 << 256}) (< normalized {1 << 224}) (< (+ normalized 2) {1 << 225}))")
    width = average_width()
    prover.prove("maximum Q96 interval width is below 0.019 atom for all u64 inputs",
        "net width fee_width",
        f"(<= 0 net) (< net {1 << 64}) (<= 0 width) (<= width {width}) (= fee_width (* net width))",
        f"(< (* 1000 fee_width) (* 19 {Q}))")
    print(f"Maximum average width: {width:,} Q96 units.")
