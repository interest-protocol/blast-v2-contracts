"""Ranking and arithmetic obligations for the pinned swap loop."""

import re

from dex_mul_div_bytecode import disassemble_module
from dex_owned_bytecode import function_bodies
from dex_tick_proof import MAX_INDEX

MAX_SWAP_STEPS = 128


def prove_swap_progress(prover):
    prover.prove("the swap step counter strictly decreases the remaining iteration budget",
        "steps next_steps",
        f"(<= 0 steps) (< steps {MAX_SWAP_STEPS}) (= next_steps (+ steps 1))",
        f"""(and (<= 0 (- {MAX_SWAP_STEPS} next_steps))
                 (< (- {MAX_SWAP_STEPS} next_steps) (- {MAX_SWAP_STEPS} steps))
                 (=> (= steps {MAX_SWAP_STEPS - 1}) (= next_steps {MAX_SWAP_STEPS})))""",
        logic="QF_LIA")
    prover.prove("a swap loop header with exhausted input, limit reached, or cap reached cannot enter",
        "remaining spot limit steps",
        f"(or (= remaining 0) (= spot limit) (= steps {MAX_SWAP_STEPS}))",
        f"(not (and (> remaining 0) (not (= spot limit)) (< steps {MAX_SWAP_STEPS})))",
        logic="QF_LIA")

    for up in (True, False):
        direction = "up" if up else "down"
        eligible = ">" if up else "<="
        post_cross = "tick" if up else "(- tick 1)"
        before_rank = f"(- {MAX_INDEX} cursor)" if up else "cursor"
        after_rank = f"(- {MAX_INDEX} next_cursor)" if up else "next_cursor"
        prover.prove(f"{direction} tick crossing consumes directional cursor distance",
            "cursor tick next_cursor",
            f"""(<= 0 cursor) (<= cursor {MAX_INDEX}) (<= 0 tick) (<= tick {MAX_INDEX})
                ({eligible} tick cursor) (= next_cursor {post_cross}) (<= 0 next_cursor)""",
            f"""(and (<= next_cursor {MAX_INDEX})
                     (<= 0 {after_rank}) (< {after_rank} {before_rank}))""",
            logic="QF_LIA")

        target = "(ite (< tick_price limit) tick_price limit)" if up else (
            "(ite (> tick_price limit) tick_price limit)")
        within_limit = "<=" if up else ">="
        prover.prove(f"{direction} zero-liquidity loop crosses only a tick within the limit or exits",
            "has_tick tick_price limit target spot next_spot",
            f"""(or (= has_tick 0) (= has_tick 1))
                (= target {target})
                (= next_spot (ite (and (= has_tick 1) (= target tick_price)) target spot))""",
            f"""(let ((crosses (and (= has_tick 1) (= target tick_price) (= next_spot tick_price))))
              (and (= crosses (and (= has_tick 1) ({within_limit} tick_price limit)))
                   (=> (not crosses) (= next_spot spot))
                   (=> (and crosses (= tick_price limit)) (= next_spot limit))))""",
            logic="QF_LIA")

    prover.prove("a downward price limit above the minimum prevents crossing index zero",
        "minimum limit target tick_price end",
        "(= tick_price minimum) (< minimum limit) (<= limit target) (<= target end)",
        "(> end tick_price)", logic="QF_LIA")
    prover.prove("a successful crossing from zero active liquidity enters a funded range",
        "active starts ends entering leaving next_active",
        """(= active 0) (<= 0 starts) (<= 0 ends) (> (+ starts ends) 0)
            (or (and (= leaving starts) (= entering ends))
                (and (= leaving ends) (= entering starts)))
            (<= leaving active) (= next_active (+ (- active leaving) entering))""",
        "(> next_active 0)", logic="QF_LIA")


def prove_output_accumulator(prover):
    """Integer spot potential for the checked Q64 loop addition."""
    u128 = 1 << 128
    u256 = 1 << 256
    scale = 1 << 32
    inverse_scale = 1 << 160
    minimum = 4_295_128_739
    maximum = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342
    cap = MAX_SWAP_STEPS
    # Down uses floor(spot / 2^32); up uses floor(2^160 / spot).
    # Leave one unit per priced step for the endpoint floors.
    prover.prove("both integer swap potentials leave room for every capped rounding pad",
        "spot direct inverse",
        f"""
        (<= {minimum} spot) (< spot {maximum})
        (<= 0 direct) (<= (* direct {scale}) spot) (< spot (* (+ direct 1) {scale}))
        (<= 0 inverse) (<= (* inverse spot) {inverse_scale})
        (< {inverse_scale} (* (+ inverse 1) spot))
        """,
        f"(and (< (+ direct {cap}) {u128}) (< (+ inverse {cap}) {u128}))", logic="QF_NIA")
    prover.prove("downward output floor is bounded by the direct potential decrease",
        "start end liquidity output start_phi end_phi",
        f"""
        (<= 0 end) (<= end start) (<= 0 liquidity) (<= 0 output)
        (<= (* output {scale}) (* liquidity (- start end)))
        (= (* start_phi {scale}) start) (= (* end_phi {scale}) end)
        """,
        "(<= output (* liquidity (- start_phi end_phi)))", logic="QF_NRA")
    prover.prove("upward nested output floors are bounded by the reciprocal potential decrease",
        "start end liquidity output start_phi end_phi",
        f"""
        (< 0 start) (<= start end) (<= 0 liquidity) (<= 0 output)
        (<= (* output start end) (* liquidity {inverse_scale} (- end start)))
        (= (* start_phi start) {inverse_scale}) (= (* end_phi end) {inverse_scale})
        """,
        "(<= output (* liquidity (- start_phi end_phi)))", logic="QF_NRA")
    prover.prove("flooring the output potentials loses less than one unit per priced step",
        "old_exact new_exact old_floor new_floor",
        """
        (<= new_exact old_exact) (<= old_floor old_exact) (< old_exact (+ old_floor 1))
        (<= new_floor new_exact) (< new_exact (+ new_floor 1))
        (or (<= new_floor old_floor) (<= (+ old_floor 1) new_floor))
        """,
        """(and (<= new_floor old_floor)
                 (< (- old_exact new_exact) (+ (- old_floor new_floor) 1)))""", logic="QF_NRA")
    prover.prove("rounded step output fits the integer potential debit and one-unit pad",
        "liquidity output exact_distance old_floor new_floor",
        f"""
        (<= 0 liquidity) (<= liquidity {u128 - 1})
        (<= 0 exact_distance) (<= new_floor old_floor)
        (< exact_distance (+ (- old_floor new_floor) 1))
        (<= 0 output) (<= output (* liquidity exact_distance))
        """,
        f"(<= output (* {u128 - 1} (+ (- old_floor new_floor) 1)))", logic="QF_NRA")
    prover.prove("priced and zero-liquidity swap steps preserve checked Q64 addition",
        "index first current next running step",
        f"""
        (<= 0 index) (< index {cap})
        (<= 0 next) (<= next current) (<= current first) (< (+ first {cap}) {u128})
        (<= 0 running) (<= running (* {u128 - 1} (+ (- first current) index)))
        (<= 0 step) (<= step (* {u128 - 1} (+ (- current next) 1)))
        """,
        f"""(and (< (+ running step) {u256})
                 (<= (+ running step) (* {u128 - 1} (+ (- first next) index 1))))""", logic="QF_LIA")


def check_swap_loop_bytecode(module):
    """Bind the accumulator and loop boundary checks to the release artifact."""
    body = function_bodies(disassemble_module(module, 0, "pool"), "pool")["swap_amounts"]
    code = re.findall(r"^\s+\d+: ([^\n]+)", body, re.M)
    ops = [re.sub(r"^(\w+Loc\[\d+\])\(.*\)$", r"\1", op) for op in code]
    slices = {
        15: "CopyLoc[21]|LdU64(0)|Gt|BrFalse(32)|Branch(20)|CopyLoc[24]|CopyLoc[3]|Neq|BrFalse(29)",
        24: "CopyLoc[26]|LdU64(128)|Lt",
        34: "MoveLoc[6]|BrFalse(173)|MoveLoc[26]|LdU64(1)|Add|StLoc[26]",
        97: "StLoc[16]|StLoc[25]|StLoc[23]|StLoc[15]|CopyLoc[15]|CopyLoc[24]|Eq|BrFalse(106)|Branch(173)",
        106: (
            "MoveLoc[15]|StLoc[24]|MoveLoc[21]|MoveLoc[23]|Sub|StLoc[21]|"
            "MoveLoc[19]|MoveLoc[25]|Add|StLoc[19]|MoveLoc[30]|CopyLoc[16]|Add|StLoc[30]"
        ),
        144: "MoveLoc[12]|BrFalse(173)|MoveLoc[27]|StLoc[24]",
        166: "Branch(15)",
        173: "MoveLoc[19]|LdU8(64)|Shr|StLoc[18]",
        216: "LdU64(18)|Abort",
        231: (
            "CopyLoc[18]|MoveLoc[22]|CastU256|Le|BrFalse(237)|Branch(239)|LdU64(13)|Abort|"
            "MoveLoc[2]|MoveLoc[21]|Sub|MoveLoc[18]|CastU64|MoveLoc[24]|MoveLoc[30]|Ret"
        ),
    }
    calls = {
        43: "curve::next_tick", 53: "curve::tick_price", 96: "continuous_fee::swap_step",
        126: "curve::credit", 132: "curve::credit", 165: "curve::cross", 172: "curve::move_inside",
    }
    if len(ops) != 247:
        raise SystemExit("Compiled swap_amounts instruction count changed.")
    for index, sequence in slices.items():
        expected = sequence.split("|")
        if ops[index:index + len(expected)] != expected:
            raise SystemExit(f"Compiled swap_amounts loop or accumulator differs at instruction {index}.")
    for index, name in calls.items():
        if not code[index].startswith(f"Call {name}("):
            raise SystemExit(f"Compiled swap_amounts does not call {name} at instruction {index}.")
    print("PASS compiled swap_amounts loop boundaries, accumulator arithmetic, and callees", flush=True)
