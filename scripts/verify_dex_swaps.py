#!/usr/bin/env python3
"""Discharge source-pinned DEX swap model obligations with the local Z3 library."""
import argparse
import ctypes
from ctypes.util import find_library
from hashlib import sha256
from pathlib import Path

from dex_curve_proof import prove_curve
from dex_fee_enclosure import prove_fee_enclosure
from dex_fee_width import prove_fee_width
from dex_mul_div_bytecode import check_bytecode, prove_compiled_branches
from dex_owned_bytecode import check_owned_bytecode
from dex_price_bytecode import prove_inverse
from dex_solvency import check_tick_prices, prove_solvency
from dex_solvency_induction import prove_abort_boundary, prove_induction, prove_position_keys
from dex_swap_progress import prove_swap_progress
from dex_tick_proof import prove_tick_lookup

SOURCE = Path(__file__).resolve().parents[1] / "scratch-sui/dex/sources"
SOURCE_HASHES = {
    "curve/curve.move": "a97f1095732aaab95e5962d7bf1d7a9b6db3d52dc4520668926ca7efc6212767",
    "curve/sqrt_price_math.move": "d875caa84bbba5c7b9300918439e048e21e89c413c05c64bb70d74e3d5fc3e47",
    "curve/tick_math.move": "8a9d877d948b43c6f993c9fdc1016989b334d9339d8f1acef75653a7c5372f5f",
    "fees/continuous_fee.move": "8d7ba8af9a11ff57adb911cf631eee0e027085e2795660716813c02c9ad699d2",
    "fees/lp_fee.move": "68547cca4d224e5bf3c4a7fd74e5ec176330e31bb7d4fc990c3827a1c7ce3ada",
    "fees/price_reference.move": "5dc92673df209c7aa26c3546bce9aaf716da6e979059c68338965a3eb7a2c9fb",
    "fees/ppm.move": "7ad9d15dd538449eea090aea52492ef65f70a3461d64784744d6cdfb7087536e",
    "lib/constants.move": "e8cd007cb22029595118c9e14dd1992e064eeced3a81b1ee2e99011c7cf2a4ce",
    "pool.move": "a84e4d157092e49430e3edd31b3c9467e451c674649a47f9ae386aed4a3ba3da",
}
Q96 = 1 << 96
Q64 = 1 << 64
U64 = 1 << 64
U128 = 1 << 128
U160 = 1 << 160
U224 = 1 << 224
U225 = 1 << 225
U256 = 1 << 256


class Prover:
    def __init__(self):
        lib = find_library("z3")
        if not lib:
            raise SystemExit("Install the Z3 shared library (libz3).")
        z3 = ctypes.CDLL(lib)
        self.z3 = z3
        self.config = z3.Z3_mk_config
        self.config.restype = ctypes.c_void_p
        self.delete_config = z3.Z3_del_config
        self.delete_config.argtypes = [ctypes.c_void_p]
        self.delete_config.restype = None
        self.context = z3.Z3_mk_context
        self.context.argtypes = [ctypes.c_void_p]
        self.context.restype = ctypes.c_void_p
        self.delete_context = z3.Z3_del_context
        self.delete_context.argtypes = [ctypes.c_void_p]
        self.delete_context.restype = None
        self.evaluate = z3.Z3_eval_smtlib2_string
        self.evaluate.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        self.evaluate.restype = ctypes.c_char_p
        z3.Z3_get_full_version.restype = ctypes.c_char_p
        print(f"Z3 {z3.Z3_get_full_version().decode()}", flush=True)
        self.count = 0

    def run(self, script):
        config = self.config()
        context = self.context(config)
        self.delete_config(config)
        try:
            return self.evaluate(context, script.encode()).decode().split()
        finally:
            self.delete_context(context)

    def fixedpoint(self, name, rules, expected=-1):
        pointer = ctypes.c_void_p
        signatures = (
            ("Z3_mk_fixedpoint", pointer, [pointer]),
            ("Z3_fixedpoint_inc_ref", None, [pointer, pointer]),
            ("Z3_fixedpoint_dec_ref", None, [pointer, pointer]),
            ("Z3_fixedpoint_from_string", pointer, [pointer, pointer, ctypes.c_char_p]),
            ("Z3_ast_vector_size", ctypes.c_uint, [pointer, pointer]),
            ("Z3_ast_vector_get", pointer, [pointer, pointer, ctypes.c_uint]),
            ("Z3_fixedpoint_query", ctypes.c_int, [pointer, pointer, pointer]),
        )
        for symbol, result, args in signatures:
            function = getattr(self.z3, symbol)
            function.restype, function.argtypes = result, args

        config = self.config()
        context = self.context(config)
        self.delete_config(config)
        fixedpoint = self.z3.Z3_mk_fixedpoint(context)
        self.z3.Z3_fixedpoint_inc_ref(context, fixedpoint)
        try:
            program = "(set-option :fp.engine spacer) (set-option :timeout 15000)\n" + rules
            queries = self.z3.Z3_fixedpoint_from_string(context, fixedpoint, program.encode())
            if self.z3.Z3_ast_vector_size(context, queries) != 1:
                raise SystemExit(f"{name}: expected one Spacer query")
            query = self.z3.Z3_ast_vector_get(context, queries, 0)
            result = self.z3.Z3_fixedpoint_query(context, fixedpoint, query)
        finally:
            self.z3.Z3_fixedpoint_dec_ref(context, fixedpoint)
            self.delete_context(context)
        if result != expected:
            raise SystemExit(f"{name}: unexpected Spacer result {result}")
        self.count += 1
        print(f"PASS {name}", flush=True)

    def prove(self, name, variables, premises, claim, logic="QF_NRA", arrays=()):
        sort = {"QF_LIA": "Int", "QF_NIA": "Int", "QF_AUFLIA": "Int", "QF_BV": "(_ BitVec 256)"}.get(logic, "Real")
        declarations = "\n".join(f"(declare-const {v} {sort})" for v in variables.split())
        declarations += "".join(f"\n(declare-const {name} (Array Int Int))" for name in arrays)
        base = f"""
            (set-logic {logic})
            (set-option :timeout 5000)
            {declarations}
            (assert (and {premises}))
        """
        # Also check that the hypotheses admit at least one assignment.
        result = self.run(base + "(check-sat)")
        if result != ["sat"]:
            raise SystemExit(f"{name}: hypotheses did not check SAT: {result}")
        result = self.run(base + f"(assert (not {claim})) (check-sat)")
        if result != ["unsat"]:
            raise SystemExit(f"{name}: negated obligation did not check UNSAT: {result}")
        self.count += 1
        print(f"PASS {name}", flush=True)


def wide_arithmetic(prover):
    prover.prove("the two-limb dispatch bounds both operands",
        "a d", "true",
        f"(= (bvult (bvor a d) (_ bv{1 << 175} 256))"
        f"   (and (bvult a (_ bv{1 << 175} 256)) (bvult d (_ bv{1 << 175} 256))))",
        logic="QF_BV")
    for width, shifts in ((30, range(0, 151, 30)), (80, (0,))):
        for shift in shifts:
            prover.prove(f"Move shift and mask expressions decompose the {width}-bit limb at {shift}",
                "b", "true",
                f"""(= (bvlshr b (_ bv{shift} 256))
                    (bvadd (bvshl (bvlshr b (_ bv{shift + width} 256)) (_ bv{width} 256))
                           (bvand (bvlshr b (_ bv{shift} 256)) (_ bv{(1 << width) - 1} 256))))""",
                logic="QF_BV")
    # a * prefix = d * quotient + remainder also covers the unrolled two-limb path.
    for bits, multiplicand, divisor in ((80, 1 << 175, 1 << 175), (30, U224, U225)):
        radix = 1 << bits
        prover.prove(f"{bits}-bit limbs preserve exact quotient and remainder",
            "a prefix divisor q r digit piece remainder",
            f"""
            (>= a 0) (>= prefix 0) (> divisor 0) (>= q 0) (>= r 0) (< r divisor)
            (>= digit 0) (< digit {radix}) (>= piece 0)
            (= (* a prefix) (+ (* divisor q) r))
            (= (+ (* r {radix}) (* a digit)) (+ (* divisor piece) remainder))
            (>= remainder 0) (< remainder divisor)
            """,
            f"""
            (and (= (* a (+ (* prefix {radix}) digit))
                    (+ (* divisor (+ (* q {radix}) piece)) remainder))
                 (<= (* q {radix}) (+ (* q {radix}) piece)))
            """)
        prover.prove(f"{bits}-bit limb shift, product and dividend fit u256",
            "a r digit",
            f"(>= a 0) (< a {multiplicand}) (>= r 0) (< r {divisor}) (>= digit 0) (< digit {radix})",
            f"(< (+ (* r {radix}) (* a digit)) {U256})")
    prover.prove("both limb schedules cover the admitted multiplier width",
        "b",
        f"(>= b 0) (< b {U160})",
        f"(and (< b {(1 << 80) ** 2}) (ite (< b {1 << 120}) (< b {(1 << 30) ** 4}) (< b {(1 << 30) ** 6})))",
        logic="QF_LIA")
    prover.prove("each prefix quotient fits when the final quotient fits",
        "a prefix b d q r",
        f"""
        (>= a 0) (>= prefix 0) (<= prefix b) (> d 0) (>= q 0) (>= r 0) (< r d)
        (= (* a prefix) (+ (* d q) r))
        (< (* a b) (* d {U256}))
        """,
        f"(< q {U256})")
    prover.prove("division with terminal round-up is a ceiling",
        "n d q r",
        "(>= q 0) (> d 0) (>= r 0) (< r d) (= n (+ (* d q) r))",
        "(let ((up (+ q (ite (> r 0) 1 0)))) (and (< (* (- up 1) d) n) (<= n (* up d))))")
    prover.prove("asset scaled delta and inverse quotients fit with rounding",
        "a b d",
        f"(>= a 0) (<= a {U224 - 1}) (>= b 0) (<= b {U160 - 1}) (> d 0) (or (<= b d) (<= a d))",
        f"(<= (* a b) (* {U224 - 1} d))")
    prover.prove("downward inverse denominator fits the limb bound",
        "liquidity net price",
        f"(> liquidity 0) (< liquidity {U128}) (>= net 0) (< net {U64}) (> price 0) (< price {U160})",
        f"(and (> (+ (* liquidity {Q96}) (* net price)) 0) (< (+ (* liquidity {Q96}) (* net price)) {U225}))")
    prover.prove("quote deltas and Q64 output quotients fit u256",
        "liquidity delta first price",
        f"(>= liquidity 0) (< liquidity {U128}) (>= delta 0) (< delta {U160}) (>= first 0) (< first {U224}) (>= price {1 << 32})",
        f"""(and (<= (* liquidity delta) (* {1 << 192} {Q96}))
            (< (* liquidity delta) (* {U256} {1 << 32}))
            (< (* first {Q64}) (* {U256} price)))""")
    prover.prove("the upward output's first quotient admits the second wide multiplication",
        "liquidity start end scaled first",
        f"""
        (<= 0 liquidity) (< liquidity {U128})
        (<= {1 << 32} start end) (< end {U160})
        (= scaled (* liquidity {Q96}))
        (<= 0 first) (<= (* first end) (* scaled (- end start)))
        """,
        f"(and (< first {U224}) (< (* first {Q64}) (* start {U256})))")
    # Interval characterizations avoid treating SMT integer division as Move division.
    prover.prove("nested ceilings equal the exact asset input ceiling",
        "n a b first result",
        """
        (>= n 0) (>= a 1) (>= b 1)
        (< (* (- first 1) a) n) (<= n (* first a))
        (< (* (- result 1) b) first) (<= first (* result b))
        (<= (+ 1 (* (- result 1) b)) first)
        """,
        "(and (< (* (- result 1) a b) n) (<= n (* result a b)))")


def price_and_output(prover):
    prover.prove("upward inverse arithmetic fits before price-limit clipping",
        "start net liquidity shift",
        f"""
        (>= start 1) (< start {U160}) (>= net 0) (< net {U64})
        (>= liquidity 1) (>= shift 0) (<= (* liquidity shift) (* net {Q96}))
        """,
        f"(and (< (* net {Q96}) {U160}) (< (+ start shift) {1 << 161}))")
    prover.prove("quote-input price is the farthest affordable grid point",
        "liquidity budget shift distance",
        f"""
        (> liquidity 0) (>= budget 0) (>= shift 0) (>= distance 0)
        (<= (* liquidity shift) (* budget {Q96}))
        (< (* budget {Q96}) (* liquidity (+ shift 1)))
        (or (<= distance shift) (>= distance (+ shift 1)))
        """,
        f"(= (<= distance shift) (<= (* liquidity distance) (* budget {Q96})))")
    prover.prove("asset-input price is the farthest affordable grid point",
        "scaled budget start end next denominator",
        """
        (> scaled 0) (>= budget 0) (> start 0) (> end 0) (<= end start)
        (= denominator (+ scaled (* budget start)))
        (< (* (- next 1) denominator) (* scaled start))
        (<= (* scaled start) (* next denominator))
        (or (>= end next) (<= end (- next 1)))
        """,
        "(= (>= end next) (<= (* scaled (- start end)) (* budget start end)))")
    prover.prove("upward clipping preserves price and budget order",
        "start next limit end target",
        """
        (<= start next) (>= limit start)
        (= target (ite (< next limit) next limit))
        (<= start end) (<= end limit)
        """,
        "(and (<= start target) (<= target limit) (= (<= end target) (<= end next)))",
        logic="QF_LIA")
    prover.prove("downward clipping preserves price and budget order",
        "start next limit end target",
        """
        (>= start next) (<= limit start)
        (= target (ite (> next limit) next limit))
        (>= start end) (>= end limit)
        """,
        "(and (>= start target) (>= target limit) (= (>= end target) (>= end next)))",
        logic="QF_LIA")
    prover.prove("ceiling a nonnegative input fits any integer budget covering its exact amount",
        "n d rounded budget",
        """
        (>= n 0) (> d 0) (>= budget 0)
        (< (* (- rounded 1) d) n) (<= n (* rounded d))
        (or (<= rounded budget) (>= rounded (+ budget 1)))
        """,
        "(= (<= rounded budget) (<= n (* budget d)))")
    prover.prove("a nonzero price move with liquidity spends at least one net atom",
        "exact_numerator divisor rounded",
        "(> exact_numerator 0) (> divisor 0) (<= exact_numerator (* rounded divisor))",
        "(> rounded 0)")
    prover.prove("asset output is conservative and its two rounding losses are bounded",
        "scaled start end delta first output loss",
        f"""
        (>= scaled 0) (> start 0) (>= end start) (= delta (- end start))
        (<= (* first end) (* scaled delta)) (< (* scaled delta) (* (+ first 1) end))
        (<= (* output start) (* first {Q64})) (< (* first {Q64}) (* (+ output 1) start))
        (= loss (- (* scaled delta {Q64}) (* output start end)))
        """,
        f"(and (>= loss 0) (< loss (* (+ {Q64} start) end)))")
    prover.prove("quote output Q64 flooring is conservative with less than one Q64 unit loss",
        "liquidity distance output",
        f"""
        (>= liquidity 0) (>= distance 0)
        (<= (* output {1 << 32}) (* liquidity distance))
        (< (* liquidity distance) (* (+ output 1) {1 << 32}))
        """,
        f"(and (<= (* output {Q96}) (* liquidity distance {Q64})) (< (* liquidity distance {Q64}) (* (+ output 1) {Q96})))")
    # For asset output use 1/start - 1/end as distance. For quote output
    # use start - end. The monotone potentials telescope across ticks.
    prover.prove("Q64 accumulation preserves the telescoping output bound",
        "sum amount bound old_potential current_potential next_potential",
        """
        (>= sum 0) (>= amount 0) (> bound 0)
        (<= old_potential current_potential) (<= current_potential next_potential)
        (<= sum (* bound (- current_potential old_potential)))
        (<= amount (* bound (- next_potential current_potential)))
        """,
        "(<= (+ sum amount) (* bound (- next_potential old_potential)))")
    prover.prove("whole-path output accumulators fit u256",
        "liquidity_bound price_span reciprocal_span",
        f"""
        (>= liquidity_bound 0) (< liquidity_bound {U128})
        (>= price_span 0) (< price_span {U160})
        (>= reciprocal_span 0) (<= (* reciprocal_span {1 << 32}) 1)
        """,
        f"""(and (< (* liquidity_bound price_span {Q64}) (* {U256} {Q96}))
                 (< (* liquidity_bound reciprocal_span {Q64} {Q96}) {U256}))""")
    prover.prove("flooring the accumulated Q64 output cannot overpay the exact path",
        "actual_so_far actual_step sum step output",
        f"""
        (<= 0 sum) (<= sum (* {Q64} actual_so_far))
        (<= 0 step) (<= step (* {Q64} actual_step))
        (<= (* output {Q64}) (+ sum step))
        (< (+ sum step) (* (+ output 1) {Q64}))
        """,
        "(<= output (+ actual_so_far actual_step))")


def fees_and_search(prover):
    prover.prove("the exact uncapped interval stays at least two thirds of a pole distance away",
        "gap pole sensitivity base cap product",
        """
        (>= gap 0) (> pole 0) (> sensitivity 0)
        (>= base 0) (<= base cap) (<= (* 10 cap) 1)
        (= (* gap gap sensitivity) (- cap base))
        (= (* pole pole sensitivity) (- 1 base))
        (<= (- 1 gap) product) (<= product (+ 1 gap))
        """,
        "(and (> (* 3 (- (+ 1 pole) product)) (* 2 pole)) (> (* 3 (- (+ product pole) 1)) (* 2 pole)))")
    prover.prove("Q96 ceiling of a fee preserves the whole-atom cap",
        "cap_upper upper fee cap_fee",
        f"""
        (>= upper 0) (<= upper cap_upper)
        (< (* (- fee 1) {Q96}) upper) (<= upper (* fee {Q96}))
        (< (* (- cap_fee 1) {Q96}) cap_upper) (<= cap_upper (* cap_fee {Q96}))
        """,
        "(<= fee cap_fee)", logic="QF_LIA")
    prover.prove("constant fee Q96 ceiling preserves its exact whole-atom ceiling",
        "net rate complement upper fee",
        f"""
        (>= net 0) (< net {U64}) (>= rate 0) (>= complement 1)
        (>= complement (* 9 rate))
        (< (* (- upper 1) complement) (* net rate {Q96}))
        (<= (* net rate {Q96}) (* upper complement))
        (<= (+ (* (- fee 1) {Q96}) 1) upper) (<= upper (* fee {Q96}))
        """,
        f"(and (< (* (- fee 1) complement) (* net rate)) (<= (* net rate) (* fee complement)) (< fee {U64}))")
    prover.prove("maximum-rate seed is affordable and maximal for fixed fees",
        "budget complement rate ppm net seed fee",
        """
        (>= budget 0) (> complement 0) (>= rate 0) (= ppm (+ complement rate))
        (>= net 0) (>= seed 0)
        (<= (* seed ppm) (* budget complement))
        (< (* budget complement) (* (+ seed 1) ppm))
        (< (* (- fee 1) complement) (* net rate))
        (<= (* net rate) (* fee complement))
        (or (<= net seed) (>= net (+ seed 1)))
        (or (<= (+ net fee) budget) (>= (+ net fee) (+ budget 1)))
        """,
        "(= (<= (+ net fee) budget) (<= net seed))")
    prover.prove("rounding net input raises the exact average fee by less than one ninth atom",
        "exact_net rounded_net average",
        """
        (>= exact_net 0) (<= exact_net rounded_net) (< (- rounded_net 1) exact_net)
        (>= average 0) (<= (* 9 average) 1)
        """,
        "(let ((extra (* (- rounded_net exact_net) average))) (and (>= extra 0) (< (* 9 extra) 1)))")
    prover.prove("gross charge is monotone given the fee enclosure",
        "net_a net_b integral_a integral_b priced_a priced_b upper_a upper_b",
        """
        (>= net_a 0) (>= net_b (+ net_a 1))
        (<= integral_a integral_b)
        (<= integral_a priced_a) (< (* 9 (- priced_a integral_a)) 1)
        (<= integral_b priced_b) (< (* 9 (- priced_b integral_b)) 1)
        (<= priced_a upper_a) (< (* 4 (- upper_a priced_a)) 1)
        (<= priced_b upper_b) (< (* 4 (- upper_b priced_b)) 1)
        """,
        "(< (+ net_a upper_a) (+ net_b upper_b))")
    prover.prove("rounding upper fees preserves gross monotonicity",
        "n1 n2 f1 f2 u1 u2",
        """
        (< (- f1 1) u1) (<= u1 f1) (< (- f2 1) u2) (<= u2 f2)
        (< (+ n1 u1) (+ n2 u2))
        (or (<= (+ n1 f1) (+ n2 f2)) (>= (+ n1 f1) (+ n2 f2 1)))
        """,
        "(<= (+ n1 f1) (+ n2 f2))")
    # The rejected endpoint is reachable from its recomputed net amount, so
    # it is also the canonical endpoint at every budget between net and mid.
    prover.prove("rejected plateau does not discard any affordable budget",
        "mid net x gross_mid gross_x budget",
        """
        (<= net mid) (> gross_mid budget) (<= gross_x budget)
        (=> (>= x mid) (>= gross_x gross_mid))
        (=> (and (>= x net) (<= x mid)) (= gross_x gross_mid))
        """,
        "(< x net)", logic="QF_LIA")
    # Endpoint coordinates increase in the direction of travel. A canonical
    # endpoint is affordable, and any farther endpoint exceeds its budget.
    prover.prove("canonical endpoint is unchanged from its net charge to the probe budget",
        "endpoint_at_net endpoint_at_probe cost_at_net cost_at_probe net probe",
        """
        (>= net 0) (<= net probe) (= cost_at_probe net)
        (>= cost_at_net 0) (<= cost_at_net net)
        (=> (< endpoint_at_net endpoint_at_probe) (> cost_at_probe net))
        (=> (> endpoint_at_net endpoint_at_probe) (> cost_at_net probe))
        """,
        "(= endpoint_at_net endpoint_at_probe)", logic="QF_LIA")
    prover.prove("a rejected probe's net charge is above the affordable lower bound",
        "lower mid net gross_lower gross_mid budget",
        """
        (< lower mid) (<= net mid) (<= gross_lower budget) (> gross_mid budget)
        (=> (<= net lower) (= gross_lower gross_mid))
        """,
        "(> net lower)", logic="QF_LIA")
    prover.prove("the rounded gross difference stays between net difference minus one and ten ninths plus two",
        "x1 x2 n1 n2 integral1 integral2 u1 u2 f1 f2",
        """
        (>= x1 0) (<= x1 x2) (>= n2 (+ n1 1))
        (< (- n1 1) x1) (<= x1 n1) (< (- n2 1) x2) (<= x2 n2)
        (<= integral1 integral2) (<= (* 9 (- integral2 integral1)) (- x2 x1))
        (<= integral1 u1) (< (* 36 (- u1 integral1)) 13)
        (<= integral2 u2) (< (* 36 (- u2 integral2)) 13)
        (< (- f1 1) u1) (<= u1 f1) (< (- f2 1) u2) (<= u2 f2)
        (or (<= f2 (- f1 2)) (>= f2 (- f1 1)))
        """,
        """
        (and (<= (- f1 1) f2)
             (< (* 9 (- (+ n2 f2) (+ n1 f1))) (+ (* 10 (- n2 n1)) 18)))
        """)
    prover.prove("the rounded fee cap cannot exceed the canonical net input",
        "net fee cap_fee",
        "(>= net 0) (>= fee 0) (<= fee cap_fee) (< (* 9 (- cap_fee 1)) net)",
        "(<= fee net)", logic="QF_LIA")
    prover.prove("the constant fee cap in Q96 is bounded by the canonical net in Q96",
        "net rate divisor cap",
        f"""
        (>= net 0) (<= 0 rate) (<= rate 100000) (= divisor (- 1000000 rate))
        (< (* (- cap 1) divisor) (* net rate {Q96}))
        (or (<= cap (* net {Q96})) (>= cap (+ (* net {Q96}) 1)))
        """,
        f"(<= cap (* net {Q96}))")
    prover.prove("rounding an upper quote clamped to the Q96 cap never exceeds integer net",
        "net cap upper fee",
        f"""
        (>= net 0) (<= 0 upper) (<= upper cap) (<= cap (* net {Q96}))
        (< (* (- fee 1) {Q96}) upper)
        """,
        "(<= fee net)", logic="QF_LIA")
    prover.prove("rejecting a quote produces a nonnegative and strictly smaller upper budget",
        "net probe budget fee excess skip next",
        f"""
        (<= 0 net) (<= net probe) (<= probe budget) (< budget {U64})
        (<= 0 fee) (<= fee net) (> (+ net fee) budget)
        (= excess (- (+ net fee) budget))
        (= skip (div (* 9 (ite (> excess 2) (- excess 2) 0)) 10))
        (= next (- net 1 skip))
        """,
        "(and (> excess 0) (<= excess fee) (<= 0 next) (< next probe))", logic="QF_LIA")
    prover.prove("the rejection jump retains every affordable canonical endpoint",
        "net rejected gross rejected_gross budget excess skip",
        """
        (<= 0 net) (< net rejected) (<= gross budget) (< budget rejected_gross)
        (< (* 9 (- rejected_gross gross)) (+ (* 10 (- rejected net)) 18))
        (= excess (- rejected_gross budget))
        (= skip (div (* 9 (ite (> excess 2) (- excess 2) 0)) 10))
        """,
        "(<= net (- rejected 1 skip))", logic="QF_LIA")
    prover.prove("the initial affordable probe or the first affordable upper probe reaches every retained endpoint",
        "canonical upper seed chosen",
        "(<= 0 canonical) (<= canonical upper) (= chosen (ite (> upper seed) upper seed))",
        "(<= canonical chosen)", logic="QF_LIA")
    prover.prove("rejected upper probes contract the distance to the last affordable budget",
        "upper threshold net excess next skip",
        """
        (<= 0 threshold) (< threshold upper) (<= (+ threshold 1) net) (<= net upper)
        (<= (- net threshold 1) excess) (> excess 0)
        (= skip (div (* 9 (ite (> excess 2) (- excess 2) 0)) 10))
        (= next (- net 1 skip))
        """,
        "(and (< next upper) (<= (- next threshold) (div (+ (- upper threshold) 27) 10)))",
        logic="QF_LIA")
    prover.prove("affordable returned gross fits u64 and covers its fee",
        "net fee budget",
        f"(>= net 0) (>= fee 0) (< budget {U64}) (<= net budget) (<= fee (- budget net))",
        f"(and (<= (+ net fee) budget) (< (+ net fee) {U64}) (<= fee (+ net fee)))",
        logic="QF_LIA")


def settlement(prover):
    prover.prove("swap loop preserves accumulated fee and input budget",
        "payment remaining fees spent fee",
        f"""
        (>= remaining 0) (<= remaining payment) (< payment {U64})
        (>= fees 0) (<= fees (- payment remaining))
        (>= spent 0) (<= spent remaining) (>= fee 0) (<= fee spent)
        """,
        f"""
        (and (>= (- remaining spent) 0)
             (<= (+ fees fee) (- payment (- remaining spent)))
             (< (+ fees fee) {U64}))
        """, logic="QF_LIA")
    # Asset and quote use the same ledger with the token roles exchanged.
    prover.prove("successful core settlement conserves each token independently",
        "payment other spent fee output reserve_in reserve_out fee_vault",
        """
        (>= fee 0) (<= fee spent) (<= spent payment) (>= other 0)
        (>= output 0) (<= output reserve_out) (>= reserve_in 0) (>= fee_vault 0)
        """,
        """
        (and (>= (- payment fee (- spent fee)) 0) (>= (- reserve_out output) 0)
             (= (+ payment reserve_in fee_vault)
                (+ (- payment spent) (+ reserve_in (- spent fee)) (+ fee_vault fee)))
             (= (+ other reserve_out) (+ (+ other output) (- reserve_out output))))
        """, logic="QF_LIA")
    prover.prove("reserve guard makes output narrowing exact",
        "output reserve",
        f"(>= output 0) (<= output reserve) (< reserve {U64})",
        f"(< output {U64})", logic="QF_LIA")


def check_source_hashes():
    for path, expected in SOURCE_HASHES.items():
        actual = sha256((SOURCE / path).read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit(f"{path} changed. Review the model against the new source before updating its pin.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiled-module", type=Path, help="sqrt_price_math.mv from a fresh sui move build")
    args = parser.parse_args()
    check_source_hashes()
    if args.compiled_module:
        check_bytecode(args.compiled_module)
        check_owned_bytecode(args.compiled_module)
    else:
        print("Model-only run. Pass --compiled-module to also check compiled tick and price arithmetic.", flush=True)
    check_tick_prices(SOURCE, args.compiled_module)
    prover = Prover()
    wide_arithmetic(prover)
    prove_compiled_branches(prover)
    prove_inverse(prover)
    price_and_output(prover)
    prove_fee_enclosure(prover)
    prove_fee_width(prover)
    fees_and_search(prover)
    prove_curve(prover)
    prove_tick_lookup(prover)
    prove_swap_progress(prover)
    settlement(prover)
    prove_solvency(prover)
    prove_position_keys(prover)
    prove_induction(prover)
    prove_abort_boundary(prover)
    print(f"{prover.count} obligations proved against the pinned swap model.")


if __name__ == "__main__":
    main()
