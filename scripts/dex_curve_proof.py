"""Arithmetic and accounting invariants for curve tick and liquidity transitions."""

MODULUS = 1 << 256
Q128 = 1 << 128


def prove_curve(prover):
    prover.prove("bitmap insertion and removal change only the selected bit",
        "bits bit",
        "(bvult bit (_ bv256 256))",
        """
        (let ((mask (bvshl (_ bv1 256) bit)))
          (let ((added (bvor bits mask)) (removed (bvand bits (bvnot mask))))
            (and (not (= mask (_ bv0 256))) (= (bvand added mask) mask)
                 (= (bvand removed mask) (_ bv0 256))
                 (= (bvand added (bvnot mask)) removed))))
        """, logic="QF_BV")
    prover.prove("valid tick indexes fit the bitmap group and bit widths",
        "index",
        "(bvule index (_ bv1774544 256))",
        """
        (and (bvult (bvlshr index (_ bv16 256)) (_ bv256 256))
             (bvult (bvurem index (_ bv256 256)) (_ bv256 256))
             (bvult (bvurem (bvlshr index (_ bv8 256)) (_ bv256 256)) (_ bv256 256)))
        """, logic="QF_BV")
    prover.prove("crossing replaces the leaving cohort with the entering cohort",
        "active retained leaving entering inactive total after",
        f"""
        (>= retained 0) (>= leaving 0) (>= entering 0) (>= inactive 0)
        (= active (+ retained leaving)) (= total (+ active entering inactive))
        (< total {Q128}) (= after (+ (- active leaving) entering))
        """,
        "(and (<= leaving active) (= after (+ retained entering)) (<= 0 after) (<= after total))",
        logic="QF_LIA")
    prover.prove("upward and downward crossing use the half-open range convention",
        "lower upper index",
        "(<= 0 lower) (< lower upper) (>= index 1)",
        """
        (and
          (=> (= index lower) (and (< (- index 1) lower) (< index upper)))
          (=> (= index upper) (and (<= lower (- index 1)) (< (- index 1) upper)))
          (=> (and (< lower index) (< index upper))
              (and (<= lower (- index 1)) (< (- index 1) upper))))
        """, logic="QF_LIA")
    prover.prove("wrapping subtraction is exactly subtraction modulo 2^256",
        "global outside flipped",
        f"""
        (<= 0 global) (< global {MODULUS}) (<= 0 outside) (< outside {MODULUS})
        (= flipped (ite (>= global outside) (- global outside)
                         (+ {MODULUS} (- global outside))))
        """,
        f"(= flipped (mod (- global outside) {MODULUS}))", logic="QF_LIA")
    prover.prove("wrapping addition is exactly addition modulo 2^256",
        "global credit next",
        f"""
        (<= 0 global) (< global {MODULUS}) (<= 0 credit) (< credit {MODULUS})
        (= next (ite (< (+ global credit) {MODULUS}) (+ global credit)
                      (- (+ global credit) {MODULUS})))
        """,
        f"(= next (mod (+ global credit) {MODULUS}))", logic="QF_LIA")
    prover.prove("crossing preserves inside growth at the boundary, even on a wrap",
        "global lower_out upper_out upper_flip lower_flip",
        f"""
        (<= 0 global) (< global {MODULUS})
        (<= 0 lower_out) (< lower_out {MODULUS}) (<= 0 upper_out) (< upper_out {MODULUS})
        (= lower_flip (mod (- global lower_out) {MODULUS}))
        (= upper_flip (mod (- global upper_out) {MODULUS}))
        """,
        f"""
        (and (= (mod (- lower_out upper_out) {MODULUS})
                (mod (- global lower_flip upper_out) {MODULUS}))
             (= (mod (- global lower_out upper_out) {MODULUS})
                (mod (- upper_flip lower_out) {MODULUS}))
             (= (mod (- global lower_flip) {MODULUS}) lower_out)
             (= (mod (- global upper_flip) {MODULUS}) upper_out))
        """, logic="QF_LIA")
    prover.prove("adding liquidity keeps both active and endpoint totals below the aggregate",
        "total active starts ends delta",
        f"""
        (<= 0 active) (<= active total) (<= 0 starts) (<= starts total)
        (<= 0 ends) (<= ends total) (<= 0 delta) (< (+ total delta) {Q128})
        """,
        f"""
        (and (< (+ starts delta) {Q128}) (< (+ ends delta) {Q128})
             (<= active (+ total delta)) (<= (+ active delta) (+ total delta)))
        """, logic="QF_LIA")
    prover.prove("removing liquidity leaves valid active and endpoint totals",
        "total active starts ends delta is_active",
        """
        (<= 0 delta) (<= delta starts) (<= starts total)
        (<= delta ends) (<= ends total) (<= 0 active) (<= active total)
        (or (and (= is_active 1) (<= delta active))
            (and (= is_active 0) (<= (+ active delta) total)))
        """,
        """
        (let ((after (ite (= is_active 1) (- active delta) active)))
          (and (<= 0 after) (<= after (- total delta))
               (<= 0 (- starts delta)) (<= (- starts delta) (- total delta))
               (<= 0 (- ends delta)) (<= (- ends delta) (- total delta))))
        """, logic="QF_LIA")
    prover.prove("crediting pre-cross active liquidity distributes no more than the funded fee",
        "funded liquidity growth_delta",
        f"""
        (<= 0 funded) (< funded {1 << 64}) (<= 1 liquidity) (< liquidity {Q128})
        (<= 0 growth_delta) (<= (* growth_delta liquidity) (* funded {Q128}))
        (< (* funded {Q128}) (* (+ growth_delta 1) liquidity))
        """,
        f"(and (< growth_delta {MODULUS}) (<= (* growth_delta liquidity) (* funded {Q128})))")
    prover.prove("partial fee withdrawal retains exactly the Q128 fractional remainder",
        "owed atoms remainder",
        f"""
        (<= 0 owed) (< owed (* {1 << 64} {Q128}))
        (= atoms (div owed {Q128})) (= remainder (mod owed {Q128}))
        """,
        f"(and (<= 0 atoms) (< atoms {1 << 64}) (<= 0 remainder) (< remainder {Q128})"
        f" (= owed (+ (* atoms {Q128}) remainder)))", logic="QF_LIA")
    prover.prove("Move's Q128 fee shift and u64 narrowing return the whole-atom quotient",
        "owed",
        f"(bvult owed (_ bv{1 << 192} 256))",
        f"""
        (let ((atoms (bvlshr owed (_ bv128 256))))
          (and (= atoms (bvudiv owed (_ bv{Q128} 256)))
               (= ((_ extract 255 64) atoms) (_ bv0 192))))
        """, logic="QF_BV")
    prover.prove("funded u64 fee shift into Q128 does not lose high bits",
        "fee",
        f"(bvult fee (_ bv{1 << 64} 256))",
        """
        (let ((scaled (bvshl fee (_ bv128 256))))
          (and (= (bvlshr scaled (_ bv128 256)) fee)
               (= ((_ extract 255 192) scaled) (_ bv0 64))))
        """, logic="QF_BV")
