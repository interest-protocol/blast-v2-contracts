"""Validate the compiled wide mul_div control flow and prove its radix arithmetic."""

from hashlib import sha256
import re
import subprocess

U256 = 1 << 256


def read_function(source, name, arguments, local_types, result="u256"):
    match = re.search(rf"^(?:public(?:\(friend\))? )?{name}\(([^\n]*)\): {result} \{{\n(.*?)^\}}", source, re.M | re.S)
    if match is None:
        raise SystemExit(f"Missing compiled {name}.")
    signature, body = match.groups()
    if [arg.split(": ", 1)[-1] for arg in signature.split(", ")] != arguments.split():
        raise SystemExit(f"Unexpected {name} signature.")
    locals_ = re.findall(r"^L(\d+):\s+[^:\n]+: ([^\n]+)", body, re.M)
    if locals_ != [(str(index), type_name)
                   for index, type_name in enumerate(local_types.split(), start=len(arguments.split()))]:
        raise SystemExit(f"Unexpected {name} local types.")
    code = []
    for pc, opcode in re.findall(r"^\s+(\d+): ([^\n]+)", body, re.M):
        if int(pc) != len(code):
            raise SystemExit(f"Unexpected {name} instruction order.")
        opcode = re.sub(r"^(\w+Loc\[\d+\])\(.*\)$", r"\1", opcode)
        opcode = re.sub(r"^LdConst\[(\d+)\]\(.*\)$", r"LdConst\1", opcode)
        opcode = re.sub(r"\[([0-9]+)\]", r"\1", opcode)
        opcode = re.sub(r"^(LdU\d+)\((\d+)\)$", r"\1:\2", opcode)
        code.append(opcode)
    return code


def disassemble(module, *options):
    return subprocess.run(["sui", "move", "disassemble", str(module), *options],
                          check=True, capture_output=True, text=True).stdout


def disassemble_module(module, address, name):
    source = disassemble(module)
    if not re.search(rf"^module {address:x}\.{name} \{{$", source, re.M):
        raise SystemExit(f"Unexpected compiled module identity for {module}.")
    return source


def check_bytecode(module):
    """Check the .mv itself by disassembling it with the Sui CLI."""
    digest = sha256(module.read_bytes()).hexdigest()
    source = disassemble_module(module, 0, "sqrt_price_math")
    for module_name in ("option", "u256"):
        if not re.search(rf"^use 0*1::{module_name};$", source, re.M):
            raise SystemExit(f"Compiled sqrt_price_math does not bind std::{module_name}.")
    divide = read_function(source, "divide", "u256 u256 bool", "u256")
    expected_divide = ("MoveLoc2|BrFalse(7)|MoveLoc0|MoveLoc1|Call u256::div_ceil(u256, u256): u256|"
                       "StLoc3|Branch(11)|MoveLoc0|MoveLoc1|Div|StLoc3|MoveLoc3|Ret")
    if divide != expected_divide.split("|") or len(divide) != 13:
        raise SystemExit("Compiled divide differs from the Sui Prover rounding contract.")

    code = read_function(source, "mul_div", "u256 u256 u256 bool",
                         "bool u8 bool u256 u256 u256 u256 u256 u256 Option<u256> u256 u256 u8")
    # A cut at 42 starts the unrolled branch. Cuts at 86 and 122 are the
    # loop header and exit. CopyLoc/MoveLoc/borrow indices are preserved.
    expected = [
        "CopyLoc0|CopyLoc1|Call u256::checked_mul(u256, u256): Option<u256>|StLoc13|ImmBorrowLoc13|"
        "Call option::is_some<u256>(&Option<u256>): bool|BrFalse(13)|MoveLoc13|"
        "Call option::destroy_some<u256>(Option<u256>): u256|MoveLoc2|MoveLoc3|"
        "Call divide(u256, u256, bool): u256|Ret",
        f"CopyLoc0|LdU256:{1 << 224}|Lt|BrFalse(29)|CopyLoc1|LdU256:{1 << 160}|Lt|BrFalse(26)|"
        f"CopyLoc2|LdU256:{1 << 225}|Lt|StLoc4|Branch(31)|LdFalse|StLoc4|Branch(31)|LdFalse|StLoc4|"
        "MoveLoc4|BrFalse(34)|Branch(36)|LdU64:13906834449221287935|Abort|"
        f"CopyLoc0|CopyLoc2|BitOr|LdU256:{1 << 175}|Lt|BrFalse(71)",
        # h = a * (b >> 80); v = ((h % d) << 80) + a * (b & mask).
        f"CopyLoc0|CopyLoc1|LdU8:80|Shr|Mul|StLoc11|CopyLoc11|CopyLoc2|Mod|LdU8:80|Shl|"
        f"MoveLoc0|MoveLoc1|LdU256:{(1 << 80) - 1}|BitAnd|Mul|Add|StLoc12|"
        "MoveLoc11|CopyLoc2|Div|LdU8:80|Shl|MoveLoc12|MoveLoc2|MoveLoc3|"
        "Call divide(u256, u256, bool): u256|Add|Ret",
        # Select 90 or 150, initialize q and r.
        f"CopyLoc1|LdU256:{1 << 120}|Lt|BrFalse(78)|LdU8:90|StLoc5|Branch(80)|LdU8:150|StLoc5|"
        "MoveLoc5|StLoc16|LdU256:0|StLoc14|LdU256:0|StLoc15",
        # v = (r << 30) + a * digit; q' = (q << 30) + v / d; r' = v % d.
        f"CopyLoc1|CopyLoc16|Shr|LdU256:{(1 << 30) - 1}|BitAnd|StLoc9|MoveLoc15|LdU8:30|Shl|"
        "CopyLoc0|MoveLoc9|Mul|Add|StLoc10|MoveLoc14|LdU8:30|Shl|CopyLoc10|CopyLoc2|Div|Add|StLoc14|"
        "MoveLoc10|CopyLoc2|Mod|StLoc15|CopyLoc16|LdU8:0|Eq|BrFalse(117)|Branch(122)|"
        "MoveLoc16|LdU8:30|Sub|StLoc16|Branch(86)",
        # Return q + (up && r > 0).
        "MoveLoc14|StLoc8|MoveLoc3|BrFalse(131)|MoveLoc15|LdU256:0|Gt|StLoc6|Branch(134)|"
        "LdFalse|StLoc6|Branch(134)|MoveLoc6|BrFalse(139)|LdU256:1|StLoc7|Branch(141)|"
        "LdU256:0|StLoc7|MoveLoc8|MoveLoc7|Add|Ret",
    ]
    expected = "|".join(expected).split("|")
    if code != expected or len(code) != 145:
        pc = next((i for i, (x, y) in enumerate(zip(code, expected)) if x != y), min(len(code), len(expected)))
        raise SystemExit(f"Compiled mul_div differs from the proof at instruction {pc}.")
    print("PASS compiled divide and mul_div signatures, types, and all 158 instructions", flush=True)
    print(f"SHA-256 of compiled sqrt_price_math.mv {digest}", flush=True)


def prove_compiled_branches(prover):
    # The driver also runs wide_arithmetic, which proves the digit extraction,
    # dividend bounds and prefix invariant used here. Move Shl truncates to
    # the operand width, so the shifted intermediates must fit independently.
    radix = 1 << 80
    prover.prove("80-bit compiled high product fits before the first division",
        "a hi",
        f"(<= 0 a) (< a {1 << 175}) (<= 0 hi) (< hi {radix})",
        f"(< (* a hi) {U256})")
    # Instantiate the Euclidean decomposition for both Div/Mod pairs.
    prover.prove("80-bit compiled limbs reconstruct the exact Euclidean division",
        "a hi lo d qh rh ql r",
        f"""
        (<= 0 a) (<= 0 hi) (< hi {radix}) (<= 0 lo) (< lo {radix})
        (> d 0) (<= 0 qh) (<= 0 rh) (< rh d)
        (= (* a hi) (+ (* qh d) rh))
        (<= 0 ql) (<= 0 r) (< r d)
        (= (+ (* rh {radix}) (* a lo)) (+ (* ql d) r))
        """,
        f"(= (* a (+ (* hi {radix}) lo)) (+ (* d (+ (* qh {radix}) ql)) r))")
    prover.prove("80-bit compiled return bounds each term by the admitted rounded quotient",
        "qh ql increment",
        f"""
        (<= 0 qh) (<= 0 ql) (or (= increment 0) (= increment 1))
        (< (+ (* qh {radix}) ql increment) {U256})
        """,
        f"(and (< (* qh {radix}) {U256}) (< (+ ql increment) {U256}))", logic="QF_LIA")
    for start, bound in ((90, 1 << 120), (150, 1 << 160)):
        prover.prove(f"30-bit compiled loop initializes its empty prefix at shift {start}",
            "b", f"(<= 0 b) (< b {bound})",
            f"(= (div b {1 << (start + 30)}) 0)", logic="QF_LIA")
    for shift in range(0, 151, 30):
        prover.prove(f"30-bit compiled shift {shift} consumes one digit with a bounded prefix",
            "b", f"(<= 0 b) (< b {1 << 160})",
            f"""
            (let ((prefix (div b {1 << shift})))
              (and (= prefix (+ (* (div b {1 << (shift + 30)}) {1 << 30})
                                 (mod prefix {1 << 30})))
                   (<= prefix b)
                   (=> (= {shift} 0) (= prefix b))))
            """, logic="QF_LIA")
    # The bytecode checks shift == 0 before the u8 subtraction. Check
    # that the two start states stay in the certified cutpoint set.
    for start in (90, 150):
        shifts = list(range(start, -1, -30))
        for index, shift in enumerate(shifts[:-1]):
            prover.prove(f"30-bit compiled shift {shift} reaches the next cut in the {start}-bit schedule",
                "current", f"(= current {shift})",
                f"(and (> current 0) (<= 0 (- current 30)) (= (- current 30) {shifts[index + 1]}))",
                logic="QF_LIA")
    prover.prove("both compiled returns fit when the chosen rounded quotient fits",
        "a b d q r increment",
        f"""
        (<= 0 a) (<= 0 b) (> d 0) (<= 0 q) (<= 0 r) (< r d)
        (= (* a b) (+ (* d q) r))
        (or (= increment 0) (and (= increment 1) (> r 0)))
        (< (* a b) (* d {U256}))
        (=> (= increment 1) (<= (* a b) (* d {U256 - 1})))
        """,
        f"(< (+ q increment) {U256})")
    prover.prove("80-bit and 30-bit recombination select the unique rounded quotient",
        "n d q r exact up",
        """
        (>= n 0) (> d 0) (>= q 0) (>= exact 0)
        (<= 0 r) (< r d) (= n (+ (* d q) r))
        (or (= up 0) (= up 1))
        (<= (* d exact) n) (< n (* d (+ exact 1)))
        (or (= q exact) (<= (+ q 1) exact) (<= (+ exact 1) q))
        """,
        """(= (+ q (ite (and (= up 1) (> r 0)) 1 0))
              (+ exact (ite (and (= up 1) (> n (* exact d))) 1 0)))""")
    for branch, a, b in (("80-bit", 1 << 170, 1 << 100),
                         ("30-bit short", 1 << 200, 1 << 100),
                         ("30-bit long", 1 << 200, 1 << 130)):
        # d = a + 1 gives a nonzero remainder and an admitted ceil of b.
        d = a + 1
        narrow = 1 << 175
        dispatch = (f"(and (< a {narrow}) (< d {narrow}))" if branch == "80-bit"
                    else f"(>= a {narrow})")
        prover.prove(f"{branch} fallback has an admitted round-up execution",
            "a b d", f"(= a {a}) (= b {b}) (= d {d})",
            f"""
            (and (>= (* a b) {U256}) (< a {1 << 224}) (< b {1 << 160}) (< d {1 << 225})
                 {dispatch}
                 (< (* (- b 1) d) (* a b)) (< (* a b) (* b d)))
            """)

    # The same domain covers the directed position and swap input deltas,
    # Q64 output deltas and the downward inverse.
    prover.prove("grid prices, u128 liquidity and u64 budgets admit every mul_div caller",
        "lo hi liquidity net first",
        f"""
        (<= {1 << 32} lo) (<= lo hi) (<= hi {(1 << 160) - 1})
        (<= 0 liquidity) (<= liquidity {(1 << 128) - 1})
        (<= 0 net) (<= net {(1 << 64) - 1})
        (<= 0 first) (<= first {(1 << 224) - 1})
        """,
        f"""
        (let ((scaled (* liquidity {1 << 96})) (delta (- hi lo)))
          (let ((d (+ scaled (* net hi))))
            (and (< scaled {1 << 224}) (< delta {1 << 160})
                 (< d {1 << 225})
                 (<= (* scaled delta) (* hi {1 << 224}))
                 (<= (* liquidity delta) (* {1 << 32} {U256 - 1}))
                 (<= (* first {1 << 64}) (* lo {U256 - 1}))
                 (=> (> liquidity 0) (and (> d 0) (<= (* scaled hi) (* hi d)))))))
        """)
