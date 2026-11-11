"""Bind the tick-grid and price-inverse models to production Move modules."""

from hashlib import sha256
import re

from dex_mul_div_bytecode import disassemble, disassemble_module, read_function

Q96 = 1 << 96
Q128 = 1 << 128
U256 = 1 << 256


def check_function(source, name, arguments, locals_, expected, result="u256"):
    actual = read_function(source, name, arguments, locals_, result)
    expected = expected.split("|")
    if actual != expected:
        pc = next((i for i, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1]),
                  min(len(actual), len(expected)))
        raise SystemExit(f"Compiled {name} differs from the price model at instruction {pc}.")


def check_tick_dependencies(module_dir, tick_disassembly):
    stdlib = module_dir / "dependencies/MoveStdlib"
    for name in ("u32", "u256"):
        if not re.search(rf"^use 0*1::{name};$", tick_disassembly, re.M):
            raise SystemExit(f"Compiled tick_math does not bind std::{name}.")
    check_function(disassemble_module(stdlib / "u32.mv", 1, "u32"), "diff", "u32 u32", "u32 u32 u32",
        "MoveLoc0|StLoc3|MoveLoc1|StLoc4|CopyLoc3|CopyLoc4|Gt|BrFalse(13)|"
        "MoveLoc3|MoveLoc4|Sub|StLoc2|Branch(17)|MoveLoc4|MoveLoc3|Sub|StLoc2|MoveLoc2|Ret",
        result="u32")
    check_function(disassemble_module(stdlib / "u256.mv", 1, "u256"), "div_ceil", "u256 u256", "u256 u256 u256",
        "MoveLoc0|StLoc3|MoveLoc1|StLoc4|CopyLoc3|CopyLoc4|Mod|LdU256:0|Eq|BrFalse(15)|"
        "MoveLoc3|MoveLoc4|Div|StLoc2|Branch(21)|MoveLoc3|MoveLoc4|Div|LdU256:1|Add|"
        "StLoc2|MoveLoc2|Ret")


def compiled_tick_constants(module):
    debug = disassemble(module, "--Xdebug")
    match = re.search(r"^    constant_pool: \[(.*?)^    \],", debug, re.M | re.S)
    if match is None:
        raise SystemExit("Compiled tick constant pool is missing.")
    data = re.findall(r"type_: (U256|Vector\(U256\)),\s+data: \[([\s\d,]+)\]", match[1])
    if match[1].count("Constant {") != 2 or [name for name, _ in data] != ["U256", "Vector(U256)"]:
        raise SystemExit("Unexpected compiled tick constant types.")
    initial, vector = [bytes(map(int, re.findall(r"\d+", value))) for _, value in data]
    # The current grid has fewer than 128 factors, so the BCS vector count is
    # one ULEB128 byte. Its elements are 32-byte little-endian u256 values.
    if len(initial) != 32 or not vector or vector[0] >= 128 or len(vector) != 1 + 32 * vector[0]:
        raise SystemExit("Invalid compiled tick constants.")
    factors = tuple(int.from_bytes(vector[i:i + 32], "little") for i in range(1, len(vector), 32))
    return int.from_bytes(initial, "little"), factors


def check_compiled_prices(module, offset):
    tick = module.with_name("tick_math.mv")
    tick_disassembly = disassemble_module(tick, 0, "tick_math")
    check_tick_dependencies(module.parent, tick_disassembly)
    check_function(tick_disassembly, "sqrt_price_x96", "u32", "u64 vector<u256> u32 u32 u256",
        f"LdU32:{offset}|StLoc4|CopyLoc0|CopyLoc4|Call u32::diff(u32, u32): u32|StLoc3|"
        "LdConst0|StLoc5|LdConst1|StLoc2|LdU64:0|StLoc1|CopyLoc3|LdU32:0|Gt|BrFalse(41)|"
        "CopyLoc3|LdU32:1|BitAnd|LdU32:0|Neq|BrFalse(32)|MoveLoc5|ImmBorrowLoc2|CopyLoc1|"
        "VecImmBorrow(2)|ReadRef|Mul|LdU8:128|Shr|StLoc5|Branch(32)|MoveLoc3|LdU8:1|Shr|"
        "StLoc3|MoveLoc1|LdU64:1|Add|StLoc1|Branch(12)|MoveLoc0|MoveLoc4|Gt|BrFalse(49)|"
        f"LdU256:{U256 - 1}|MoveLoc5|Div|StLoc5|MoveLoc5|LdU256:{1 << 32}|"
        "Call u256::div_ceil(u256, u256): u256|Ret")
    check_function(disassemble_module(module, 0, "sqrt_price_math"), "next_price", "u256 u128 u64 bool", "u256 u256",
        "MoveLoc3|BrFalse(12)|MoveLoc0|MoveLoc2|CastU256|LdU8:96|Shl|MoveLoc1|CastU256|Div|Add|Ret|"
        "MoveLoc1|CastU256|LdU8:96|Shl|StLoc5|CopyLoc5|MoveLoc2|CastU256|CopyLoc0|Mul|Add|"
        "StLoc4|MoveLoc5|MoveLoc0|MoveLoc4|LdTrue|Call mul_div(u256, u256, u256, bool): u256|Ret")
    initial, factors = compiled_tick_constants(tick)
    if initial != Q128 or len(factors) != offset.bit_length():
        raise SystemExit("The compiled tick constants do not cover the certified grid.")
    print(f"PASS compiled tick grid, its integer dependencies and both inverse paths", flush=True)
    print(f"SHA-256 of compiled tick_math.mv {sha256(tick.read_bytes()).hexdigest()}", flush=True)
    return factors


def prove_inverse(prover):
    prover.prove("compiled upward inverse is a bounded floor and cannot move down",
        "start net liquidity quotient remainder",
        f"""
        (<= {1 << 32} start) (< start {1 << 160}) (<= 0 net) (<= net {(1 << 64) - 1})
        (<= 1 liquidity) (<= liquidity {(1 << 128) - 1})
        (<= 0 quotient) (<= 0 remainder) (< remainder liquidity)
        (= (* net {Q96}) (+ (* liquidity quotient) remainder))
        """,
        f"""
        (and (<= start (+ start quotient)) (< (+ start quotient) {1 << 161})
             (< (* net {Q96}) (* liquidity (+ quotient 1)))
             (<= (* liquidity quotient) (* net {Q96})))
        """)
    # The solver uses Reals for the nonlinear arithmetic. The last premise
    # restricts the two integer prices to the corresponding unit-step order.
    prover.prove("compiled downward inverse admits mul_div and its ceiling cannot move up",
        "start net liquidity denominator price",
        f"""
        (<= {1 << 32} start) (< start {1 << 160}) (<= 0 net) (<= net {(1 << 64) - 1})
        (<= 1 liquidity) (<= liquidity {(1 << 128) - 1})
        (= denominator (+ (* liquidity {Q96}) (* net start)))
        (< (* (- price 1) denominator) (* liquidity {Q96} start))
        (<= (* liquidity {Q96} start) (* price denominator))
        (or (<= price start) (>= price (+ start 1)))
        """,
        f"""
        (and (> denominator 0) (< denominator {1 << 225}) (>= price 1) (<= price start)
             (or (< (* liquidity {Q96} start) {U256})
                 (and (< (* liquidity {Q96}) {1 << 224}) (< start {1 << 160})
                      (< denominator {1 << 225}) (< price {U256}))))
        """)

    for up in (True, False):
        order = ("(<= minimum start limit) (< limit maximum)" if up else
                 "(<= minimum limit start) (< start maximum)")
        clamp = ("(= end (ite (<= next limit) next limit))" if up else
                 "(= end (ite (>= next limit) next limit))")
        inverse = (
            """
            (= next (+ start quotient)) (>= quotient 0)
            (<= 0 remainder) (< remainder stake)
            (= (* budget unit) (+ (* stake quotient) remainder))
            """ if up else """
            (<= 1 next start)
            (= denominator (+ scaled (* budget start)))
            (<= (* scaled start) (* next denominator))
            """
        )
        domain = "(<= start end limit)" if up else "(<= limit end start)"
        numerator = "(* stake (- end start))" if up else "(* scaled (- start end))"
        divisor = "unit" if up else "(* start end)"
        direction = "upward" if up else "downward"
        prover.prove(f"{direction} inverse clipping supplies the trial price and net-budget preconditions",
            "minimum maximum start limit next end stake budget net unit scaled quotient remainder denominator",
            f"""
            (> minimum 0) (> stake 0) (> unit 0) (= scaled (* stake unit))
            (>= budget 0) (>= net 0)
            {order} {inverse} {clamp}
            (< (* (- net 1) {divisor}) {numerator}) (<= {numerator} (* net {divisor}))
            (or (<= net budget) (>= net (+ budget 1)))
            (or (= net 0) (>= net 1))
            """,
            f"(and {domain} (<= minimum end) (< end maximum) (<= net budget) (=> (= end start) (= net 0)))")
