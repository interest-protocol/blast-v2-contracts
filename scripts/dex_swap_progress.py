"""Ranking and zero-liquidity branch obligations for the pinned swap loop."""

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
