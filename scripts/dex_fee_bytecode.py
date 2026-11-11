"""Check the compiled fee-weight loop and its directed quotient."""

import re

from dex_mul_div_bytecode import disassemble, disassemble_module, read_function

Q96 = 1 << 96
LIMB = 1 << 32


def check_fee_weight_bytecode(module):
    source = disassemble_module(module, 0, "continuous_fee")
    point = read_function(source, "point", "u256", "", "Interval")
    if point != ["CopyLoc0", "MoveLoc0", "Pack0(Interval)", "Ret"]:
        raise SystemExit("Compiled point differs from the fee-weight proof.")
    weight = read_function(source, "bounded_fraction", "u256 u256",
                           "u256 u256 u256 u64 u256 u256 u256", "Interval")
    expected = (
        "CopyLoc0|CopyLoc1|Eq|BrFalse(7)|LdConst0|Call point(u256): Interval|Ret|"
        "CopyLoc0|CopyLoc1|Lt|BrFalse(12)|Branch(14)|LdU64:13906835952459841535|Abort|"
        "MoveLoc0|StLoc7|LdU256:0|StLoc6|LdU64:0|StLoc5|"
        "CopyLoc5|LdU64:3|Lt|BrFalse(47)|CopyLoc5|Pop|"
        "MoveLoc7|LdU8:32|Shl|StLoc8|MoveLoc6|LdU8:32|Shl|CopyLoc8|CopyLoc1|Div|Add|StLoc6|"
        "MoveLoc8|CopyLoc1|Mod|StLoc7|MoveLoc5|LdU64:1|Add|StLoc5|Branch(20)|"
        "CopyLoc6|StLoc4|MoveLoc6|StLoc3|MoveLoc7|LdU256:0|Gt|BrFalse(58)|"
        "LdU256:1|StLoc2|Branch(60)|LdU256:0|StLoc2|MoveLoc4|MoveLoc3|MoveLoc2|Add|Pack0(Interval)|Ret"
    )
    if weight != expected.split("|"):
        raise SystemExit("Compiled bounded_fraction differs from the fee-weight proof.")
    debug = disassemble(module, "--Xdebug")
    constant = re.search(r"^    constant_pool: \[\s*Constant \{\s*type_: U256,\s*data: \[([\d,\s]+)\]", debug, re.M)
    if constant is None or bytes(map(int, re.findall(r"\d+", constant[1]))) != Q96.to_bytes(32, "little"):
        raise SystemExit("Compiled bounded_fraction does not return Q96 for equal inputs.")
    print("PASS compiled bounded_fraction and point instructions and Q96 constant", flush=True)


def prove_fee_weight(prover):
    # The equal case returns point(Q96). Otherwise 0 <= numerator < denominator
    # initializes q = 0, r = numerator. Div and Mod maintain the Euclidean
    # identity checked by the enclosure proof on each of the three loop edges.
    for index in range(3):
        scale = LIMB**index
        prover.prove(f"compiled fee-weight limb {index + 1} returns within its quotient and shift bounds",
            "den q r digit next_r",
            f"""
            (<= 0 q) (< q {scale}) (<= 0 r) (< r den) (< den {1 << 224})
            (<= 0 digit) (<= 0 next_r) (< next_r den)
            (= (* r {LIMB}) (+ (* digit den) next_r))
            """,
            f"""(and (> den 0) (< (* r {LIMB}) {1 << 256})
                     (< (* q {LIMB}) {1 << 256}) (< digit {LIMB})
                     (< (+ (* q {LIMB}) digit) {scale * LIMB}))""", logic="QF_NIA")
    prover.prove("compiled fee-weight return is an ordered floor and ceiling",
        "den num quotient remainder upper",
        f"""
        (> den 0) (<= 0 num) (< num den) (<= 0 quotient) (< quotient {Q96})
        (<= 0 remainder) (< remainder den)
        (= (* num {Q96}) (+ (* quotient den) remainder))
        (= upper (+ quotient (ite (> remainder 0) 1 0)))
        """,
        f"""(and (<= quotient upper) (<= upper {Q96})
                 (<= (* quotient den) (* num {Q96}))
                 (<= (* num {Q96}) (* upper den))
                 (< (* num {Q96}) (* (+ quotient 1) den))
                 (< (* (- upper 1) den) (* num {Q96})))""", logic="QF_NIA")


def prove_fee_partition(prover):
    prover.prove("appended fee cuts strictly increase inside the normalized path",
        "start end last candidate next",
        f"""
        (<= 0 start) (<= start last) (< last end) (< end {1 << 224})
        (= next (ite (and (> candidate start) (< candidate end) (> candidate last)) candidate last))
        """,
        "(and (<= last next) (< next end) (=> (not (= next last)) (< last next)))",
        logic="QF_LIA")
    prover.prove("the reference cut is present whenever the normalized path straddles it",
        "start end last next",
        f"""
        (< start {Q96}) (< {Q96} end) (<= start last) (<= last {Q96})
        (= next (ite (and (> {Q96} start) (< {Q96} end) (> {Q96} last)) {Q96} last))
        """,
        f"(= next {Q96})", logic="QF_LIA")
    prover.prove("a consecutive segment admits the compiled fee-weight divisor and numerator",
        "start end low high",
        f"(<= 0 start) (<= start low) (< low high) (<= high end) (< end {1 << 224})",
        f"(and (< 0 (- high low)) (<= (- high low) (- end start)) (< (- end start) {1 << 224}))",
        logic="QF_LIA")
    prover.prove("directed segment weights preserve the average bounds on a path prefix",
        "base cap whole prefix next_prefix low hi term_low term_hi wlow whigh slow shigh",
        f"""
        (<= 0 base) (<= base cap) (< 0 whole) (<= 0 prefix) (< prefix next_prefix) (<= next_prefix whole)
        (<= 0 low) (<= 0 hi) (<= (* low whole) (* cap prefix)) (<= (* base prefix) (* hi whole))
        (<= 0 slow) (<= slow cap) (<= base shigh)
        (<= 0 wlow) (<= (* wlow whole) (* (- next_prefix prefix) {Q96}))
        (<= (* (- next_prefix prefix) {Q96}) (* whigh whole))
        (<= 0 term_low) (<= (* term_low {Q96}) (* wlow slow))
        (<= (* whigh shigh) (* term_hi {Q96}))
        """,
        """(and (<= (* (+ low term_low) whole) (* cap next_prefix))
                 (<= (* base next_prefix) (* (+ hi term_hi) whole)))""")
