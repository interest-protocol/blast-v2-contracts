"""Bit-level and order proofs for the source-pinned DEX tick bitmap."""

MAX_INDEX = 1_774_544
WIDTH = 256


def bv(value):
    return f"(_ bv{value} {WIDTH})"


def mask_at(bit):
    return f"(bvshl {bv(1)} {bit})"


def occupied(bits, bit):
    return f"(not (= (bvand {bits} {mask_at(bit)}) {bv(0)}))"


def masks_and_scan(prover):
    for up in (True, False):
        relation = "bvuge" if up else "bvule"
        strict = "bvugt" if up else "bvult"
        direction = "up" if up else "down"
        # Fix the cutoff and leave the probe symbolic. The 256 cutoffs
        # exhaust u8, including both ends of the word.
        for pivot in range(WIDTH):
            bit = 1 << pivot
            lower = bit - 1
            inclusive = ((1 << WIDTH) - 1) ^ lower if up else lower | bit
            exclusive = inclusive ^ bit
            prover.prove(f"{direction} masks at cutoff {pivot} retain exactly the eligible bits",
                "probe", f"(bvult probe {bv(WIDTH)})",
                f"""(and (= {occupied(bv(inclusive), 'probe')} ({relation} probe {bv(pivot)}))
                          (= {occupied(bv(exclusive), 'probe')} ({strict} probe {bv(pivot)})))""",
                logic="QF_BV")

    # Check the exact support of each half at all eight production shifts.
    # Extremality follows by induction: a nonempty preferred half wins;
    # translation by the split size preserves order inside the high half.
    for shift in (128, 64, 32, 16, 8, 4, 2, 1):
        half = bv(shift)
        low = f"(bvand bits {bv((1 << shift) - 1)})"
        high = f"(bvlshr bits {half})"
        bounded = f"(bvult bits {bv(1 << (2 * shift))})" if shift < 128 else "true"
        prover.prove(f"scan split at {shift} preserves support and bounds both halves", "bits probe",
            f"{bounded} (bvult probe {half})",
            f"""(and (bvult {low} {bv(1 << shift)}) (bvult {high} {bv(1 << shift)})
                     (= {occupied(low, 'probe')} {occupied('bits', 'probe')})
                     (= {occupied(high, 'probe')} {occupied('bits', f'(bvadd probe {half})')})
                     (= (= bits {bv(0)}) (and (= {low} {bv(0)}) (= {high} {bv(0)}))))""",
            logic="QF_BV")
    prover.prove("scan offset preserves the extreme index in the preferred nonempty half",
        "split extreme translated other first_high low_live high_live",
        """(> split 0) (<= 0 translated) (< translated split)
            (or (and (= low_live 0) (= high_live 1)) (and (= low_live 1) (= high_live 0))
                (and (= low_live 1) (= high_live 1)))
            (or (= first_high 0) (= first_high 1))
            (let ((take_high (and (= high_live 1) (or (= first_high 1) (= low_live 0)))))
              (and (= extreme (+ translated (ite take_high split 0)))
                   (or (and (= low_live 1) (<= 0 other) (< other split))
                       (and (= high_live 1) (<= split other) (< other (* 2 split))))
                   (=> (and take_high (<= split other))
                       (ite (= first_high 1) (>= translated (- other split)) (<= translated (- other split))))
                   (=> (and (not take_high) (< other split))
                       (ite (= first_high 1) (>= translated other) (<= translated other)))))""",
        "(ite (= first_high 1) (>= extreme other) (<= extreme other))", logic="QF_LIA")


def prove_tick_lookup(prover):
    masks_and_scan(prover)
    prover.prove("bounded cursor search intervals stay nonempty and strictly shrink",
        "start lo hi end mid next_lo next_hi",
        f"""(<= 0 start) (<= start lo) (< lo hi) (<= hi end) (<= end {MAX_INDEX})
             (= mid (+ lo (div (+ (- hi lo) 1) 2)))
             (or (and (= next_lo mid) (= next_hi hi))
                 (and (= next_lo lo) (= next_hi (- mid 1))))""",
        "(and (< lo mid) (<= mid hi) (<= start next_lo) (<= next_lo next_hi)"
        " (<= next_hi end) (< (- next_hi next_lo) (- hi lo)))", logic="QF_LIA")
    prover.prove("bitmap coordinate decomposition fits the lookup, including max cursor plus one",
        "start word group bit slot",
        f"""(bvule start {bv(MAX_INDEX + 1)})
            (= word (bvlshr start {bv(8)})) (= group (bvlshr word {bv(8)}))
            (= bit (bvurem start {bv(256)})) (= slot (bvurem word {bv(256)}))""",
        f"""(and (bvult group {bv(28)}) (bvult word {bv(1 << 16)})
                 (= start (bvadd (bvshl word {bv(8)}) bit))
                 (= word (bvadd (bvshl group {bv(8)}) slot))
                 (bvult (bvadd (bvshl word {bv(8)}) {bv(255)}) {bv(1 << 32)}))""", logic="QF_BV")
    prover.prove("other initialized groups and words reconstruct an in-range u32 key",
        "group slot bit",
        f"(bvult group {bv(256)}) (bvult slot {bv(256)}) (bvult bit {bv(256)})",
        f"""(let ((word (bvadd (bvshl group {bv(8)}) slot)))
              (let ((tick (bvadd (bvshl word {bv(8)}) bit)))
                (and (bvult tick {bv(1 << 24)}) (= (bvlshr tick {bv(8)}) word)
                     (= (bvlshr word {bv(8)}) group)
                     (= (bvurem tick {bv(256)}) bit)
                     (= (bvurem word {bv(256)}) slot))))""", logic="QF_BV")
    prover.prove("lexicographic group, word and bit order equals tick index order",
        "g w b other_g other_w other_b",
        "(<= 0 b) (< b 256) (<= 0 other_b) (< other_b 256)"
        " (<= 0 w) (< w 256) (<= 0 other_w) (< other_w 256)",
        """(= (< (+ (* g 65536) (* w 256) b) (+ (* other_g 65536) (* other_w 256) other_b))
               (or (< g other_g) (and (= g other_g) (< w other_w))
                   (and (= g other_g) (= w other_w) (< b other_b))))""", logic="QF_LIA")

    for up in (True, False):
        strict = ">" if up else "<"
        eligible = ">=" if up else "<="
        better = "<" if up else ">"
        direction = "up" if up else "down"
        prover.prove(f"{direction} lookup partitions every eligible tick into its three search regions",
            "cursor group word bit g w b tick",
            f"""(<= 0 bit) (< bit 256) (<= 0 word) (< word 256)
                (<= 0 b) (< b 256) (<= 0 w) (< w 256)
                (= (+ cursor {int(up)}) (+ (* group 65536) (* word 256) bit))
                (= tick (+ (* g 65536) (* w 256) b))""",
            f"""(= ({strict if up else eligible} tick cursor)
                  (or ({strict} g group)
                      (and (= g group) ({strict} w word))
                      (and (= g group) (= w word) ({eligible} b bit))))""", logic="QF_LIA")
        region = lambda r, g, w: (
            f"(or (and (= {r} 0) (= {g} cg) (= {w} cw))"
            f" (and (= {r} 1) (= {g} cg) ({strict} {w} cw))"
            f" (and (= {r} 2) ({strict} {g} cg)))")
        prover.prove(f"{direction} first occupied region and extreme coordinates are globally nearest",
            "cg cw region other_region g w b other_g other_w other_b",
            f"""(<= region other_region) {region('region', 'g', 'w')}
                {region('other_region', 'other_g', 'other_w')}
                (<= 0 b) (< b 256) (<= 0 other_b) (< other_b 256)
                (<= 0 w) (< w 256) (<= 0 other_w) (< other_w 256)
                (=> (= region other_region 2) (not ({better} other_g g)))
                (=> (and (= region other_region) (= g other_g) (> region 0))
                    (not ({better} other_w w)))
                (=> (and (= g other_g) (= w other_w)) (not ({better} other_b b)))""",
            f"""(not ({better} (+ (* other_g 65536) (* other_w 256) other_b)
                                (+ (* g 65536) (* w 256) b)))""", logic="QF_LIA")

    prover.prove("changing one child preserves the occupancy relation at an arbitrary key",
        "key changed old_child old_bit new_child new_bit",
        """(>= old_child 0) (>= new_child 0)
            (= (= old_child 0) (= old_bit 0))
            (=> (= key changed) (= (= new_child 0) (= new_bit 0)))
            (=> (not (= key changed)) (and (= old_child new_child) (= old_bit new_bit)))""",
        "(= (= new_child 0) (= new_bit 0))", logic="QF_LIA")
    prover.prove("an in-range update cannot set a bit for an out-of-range tick",
        "key changed",
        f"(<= 0 changed) (<= changed {MAX_INDEX}) (> key {MAX_INDEX})",
        "(not (= key changed))", logic="QF_LIA")
    prover.prove("every present parent path leads to existing nonempty child tables",
        "top_bit group_present group_word word_bit word_present tick_word",
        """(= (= top_bit 0) (= group_word 0)) (= (= group_present 0) (= group_word 0))
            (= (= word_bit 0) (= tick_word 0)) (= (= word_present 0) (= tick_word 0))
            (not (= top_bit 0)) (not (= word_bit 0))""",
        "(and (not (= group_present 0)) (not (= group_word 0))"
        " (not (= word_present 0)) (not (= tick_word 0)))", logic="QF_LIA")
