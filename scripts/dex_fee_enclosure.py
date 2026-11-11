"""Algebraic obligations for the continuous fee enclosure.

The integral identities and composition of these obligations are in
scratch-sui/continuous-fee-proof.md. Variables with Q96 units are identified
in each obligation. Every check has a satisfiable antecedent.
"""

Q = 1 << 96


def interval_arithmetic(prover):
    prover.prove("directed Q96 multiplication encloses products",
        "al ah bl bh a b lo hi",
        f"""
        (<= 0 al) (<= al a) (<= a ah) (<= 0 bl) (<= bl b) (<= b bh)
        (<= (* lo {Q}) (* al bl)) (>= (* hi {Q}) (* ah bh))
        """,
        f"(and (<= (* lo {Q}) (* a b)) (>= (* hi {Q}) (* a b)))")
    prover.prove("directed Q96 division encloses quotients",
        "al ah bl bh a b lo hi",
        f"""
        (<= 0 al) (<= al a) (<= a ah) (< 0 bl) (<= bl b) (<= b bh)
        (<= (* lo bh) (* al {Q})) (>= (* hi bl) (* ah {Q})) (<= 0 lo)
        """,
        f"(and (<= (* lo b) (* a {Q})) (>= (* hi b) (* a {Q})))")
    prover.prove("directed square root encloses scaled square roots",
        "lo hi a root rlo rhi",
        f"""
        (<= 0 lo) (<= lo a) (<= a hi) (<= 0 root) (= (* root root) (* a {Q}))
        (<= 0 rlo) (<= (* rlo rlo) (* lo {Q}))
        (<= 0 rhi) (>= (* rhi rhi) (* hi {Q}))
        """,
        "(and (<= rlo root) (<= root rhi))")
    prover.prove("Newton square root updates stay above the floor root",
        "n root floor_root quotient next",
        """
        (<= 0 floor_root) (>= root floor_root) (> root 0)
        (<= (* floor_root floor_root) n)
        (<= (* quotient root) n) (< n (* (+ quotient 1) root))
        (or (>= quotient (- (* 2 floor_root) root))
            (<= (+ quotient 1) (- (* 2 floor_root) root)))
        (<= (* 2 next) (+ root quotient)) (< (+ root quotient) (* 2 (+ next 1)))
        (or (>= next floor_root) (<= (+ next 1) floor_root))
        """,
        "(>= next floor_root)")
    prover.prove("Newton's nondecreasing exit returns the floor root",
        "n root floor_root quotient next",
        """
        (<= 0 floor_root) (>= root floor_root) (> root 0)
        (< n (* (+ floor_root 1) (+ floor_root 1)))
        (<= (* quotient root) n) (<= (* 2 next) (+ root quotient)) (>= next root)
        (or (= root floor_root) (>= root (+ floor_root 1)))
        """,
        "(= root floor_root)")
    prover.prove("absolute difference uses the correct nearest and farthest endpoints",
        "al ah bl bh a b",
        """
        (<= al a) (<= a ah) (<= bl b) (<= b bh)
        """,
        """
        (let ((diff (ite (>= a b) (- a b) (- b a)))
              (alo (ite (>= al bh) (- al bh) (ite (>= bl ah) (- bl ah) 0)))
              (left (ite (>= al bh) (- al bh) (- bh al)))
              (right (ite (>= ah bl) (- ah bl) (- bl ah))))
          (and (<= alo diff) (<= diff (ite (> left right) left right))))
        """)
    prover.prove("clamping an interval to independently proved bounds preserves enclosure",
        "lo hi x base cap",
        "(<= lo x) (<= x hi) (<= base x) (<= x cap)",
        "(and (<= (ite (> lo base) lo base) x) (<= x (ite (< hi cap) hi cap)))")
    limb = 1 << 32
    prover.prove("three-limb fee weights preserve the division invariant",
        "d n scale r q digit next_r",
        f"""
        (> d 0) (>= n 0) (< n d) (>= scale 1)
        (>= r 0) (< r d) (= (* n scale) (+ (* q d) r))
        (>= next_r 0) (< next_r d) (= (* r {limb}) (+ (* digit d) next_r))
        """,
        f"(= (* n scale {limb}) (+ (* d (+ (* q {limb}) digit)) next_r))")
    prover.prove("fee weight remainder shift retains all bits",
        "r d",
        f"(>= r 0) (< r d) (< d {1 << 224})",
        f"(< (* r {limb}) {1 << 256})",
        logic="QF_LIA")


def integral_identity(prover):
    # This identity supplies both Mobius substitutions, since reversing the
    # sign of both factors leaves their product unchanged.
    prover.prove("the pole substitution denominator factors exactly",
        "a t start",
        "(> t 0) (> start 0) (> a (* t t))",
        """
        (= (- (* (- a (* start t)) (- a (* start t))) (* a (- t start) (- t start)))
           (* (- a (* start start)) (- a (* t t))))
        """)
    prover.prove("partial fractions have the continuous curve's exact denominator",
        "t w k base a z",
        """
        (> t 0) (> w 0) (> k 0) (= (* k w w) (- 1 base))
        (= a (+ 1 w)) (= z (- 1 w))
        """,
        "(= (* k (- a (* t t)) (- (* t t) z)) (- 1 base (* k (- (* t t) 1) (- (* t t) 1))))")
    prover.prove("the two pole prefactors sum to the exact gross density",
        "a z t2 k w first second",
        """
        (> k 0) (> w 0) (= (- a z) (* 2 w))
        (= first (- a t2)) (= second (- t2 z))
        (> first 0) (> second 0)
        """,
        "(= (* k (+ first second)) (* 2 k w))")
    prover.prove("reciprocal-coordinate correction agrees with both pole primitives",
        "d p pole delta argument j h",
        """
        (> d 0) (> p 0) (>= delta 0)
        (or (= (+ d p) pole) (= (- p d) pole))
        (= (* argument d d) (* pole delta delta))
        (= h (+ 1 (* argument j)))
        """,
        """
        (and
          (=> (= (+ d p) pole)
              (= (* (+ d (* p h)) d d) (* pole (+ (* d d) (* p delta delta j)))))
          (=> (= (- p d) pole)
              (= (* (- (* p h) d) d d) (* pole (+ (* d d) (* p delta delta j))))))
        """)
    prover.prove("zero lower pole has the same reciprocal-coordinate limit",
        "t0 t1 p delta",
        "(> t0 0) (>= t1 t0) (= p (* t0 t1)) (= delta (- t1 t0))",
        "(= (+ (* 3 p) (* delta delta)) (+ (* t0 t0) p (* t1 t1)))")
    prover.prove("admitted fee parameters bound the pole and the cap gap",
        "k c b g w",
        """
        (>= (* 10 k) 1) (>= b 0) (>= c b) (<= (* 10 c) 1)
        (>= g 0) (> w 0) (= (* k g g) (- c b)) (= (* k w w) (- 1 b))
        """,
        "(and (< (* 5 w) 16) (< (* 25 g) (* 8 w)))")
    prover.prove("positive admitted base fee keeps both cap roots strictly positive",
        "k c b g low high",
        """
        (>= (* 10 k) 1) (>= (* 1000000 b) 1) (> c b) (<= (* 10 c) 1)
        (>= g 0) (= (* k g g) (- c b))
        (>= low 0) (>= high 0) (= (* low low) (- 1 g)) (= (* high high) (+ 1 g))
        """,
        "(and (> low (/ 1 500)) (< low 1) (> high 1) (< high (/ 3 2)))")
    # For intervals below one, delta <= g. Above one, delta <= g/2.
    prover.prove("reference-split endpoints constrain product and delta",
        "t0 t1 g p delta",
        """
        (>= g 0) (> t0 0) (>= t1 t0) (<= (- 1 g) (* t0 t0)) (<= (* t1 t1) (+ 1 g))
        (= p (* t0 t1)) (= delta (- t1 t0)) (or (<= t1 1) (>= t0 1))
        """,
        """
        (and (<= (- 1 g) p) (<= p (+ 1 g))
             (=> (<= t1 1) (and (<= p 1) (<= delta g)))
             (=> (>= t0 1) (<= (* 2 delta) g)))
        """)
    prover.prove("both exact series arguments are below 0.49",
        "g w p delta a d1 d2 z_abs",
        """
        (>= g 0) (> w 0) (<= (* 5 w) 16) (<= (* 25 g) (* 8 w))
        (<= (- 1 g) p) (<= p (+ 1 g)) (>= delta 0)
        (or (and (<= p 1) (<= delta g)) (<= (* 2 delta) g))
        (= a (+ 1 w)) (= d1 (- a p)) (= d2 (- (+ p w) 1))
        (= z_abs (ite (>= w 1) (- w 1) (- 1 w)))
        """,
        """
        (and (> d1 0) (> d2 0)
             (< (* 100 a delta delta) (* 49 d1 d1))
             (< (* 100 z_abs delta delta) (* 49 d2 d2)))
        """)


def series_enclosure(prover):
    prover.prove("fixed-point powers lose less than two Q96 units per recurrence",
        "x rounded exact next actual",
        f"""
        (<= 0 x) (<= (* 2 x) {Q}) (<= 0 rounded) (<= rounded exact) (< exact (+ rounded 2))
        (<= (* next {Q}) (* rounded x)) (< (* rounded x) (* (+ next 1) {Q}))
        (= (* actual {Q}) (* exact x))
        """,
        "(and (<= next actual) (< actual (+ next 2)))")
    prover.prove("each floored series term loses less than three Q96 units",
        "power actual denom term exact",
        """
        (<= 0 power) (<= power actual) (< actual (+ power 2)) (>= denom 1)
        (<= (* term denom) power) (< power (* (+ term 1) denom)) (= (* exact denom) actual)
        """,
        "(and (<= term exact) (< exact (+ term 3)))")
    prover.prove("three units per term bound both ordinary and alternating sums",
        "approx exact term exact_term n sign",
        """
        (>= n 1) (<= (- (* 3 n)) (- exact approx)) (<= (- exact approx) (* 3 n))
        (<= term exact_term) (< exact_term (+ term 3))
        (or (= sign 1) (= sign (- 1)))
        """,
        """
        (let ((err (+ (- exact approx) (* sign (- exact_term term)))))
          (and (<= (- (* 3 (+ n 1))) err) (<= err (* 3 (+ n 1)))))
        """)
    prover.prove("alternating term pairs cannot underflow their running sum",
        "sum even odd",
        "(>= even 0) (>= odd 0) (>= sum even) (>= even odd)",
        "(>= (- sum odd) 0)",
        logic="QF_LIA")
    prover.prove("directed tail covers the first omitted term and its geometric tail",
        "x power actual next_ceil tail denominator",
        f"""
        (>= x 0) (<= (* 2 x) {Q}) (>= power 0) (>= actual power) (<= actual (+ power 2))
        (>= (* next_ceil {Q}) (* (+ power 2) x))
        (>= denominator 1)
        (>= (* tail (- {Q} x) denominator) (* next_ceil {Q}))
        """,
        f"(>= (* tail (- {Q} x) denominator) (* actual x))")
    prover.prove("geometric sum recurrence preserves the signed remainder",
        "r sum next",
        "(< r 1) (= (* (- 1 r) sum) (- 1 next))",
        "(= (- 1 (* (- 1 r) (+ sum next))) (* r next))")
    prover.prove("the offset-three integrand gives the correction to the offset-one integrand",
        "x u offset_one offset_three",
        """
        (<= (- (/ 1 2)) x) (<= x (/ 1 2)) (<= 0 u) (<= u 1)
        (= (* offset_one (- 1 (* x u u))) 1)
        (= (* offset_three (- 1 (* x u u))) (* u u))
        """,
        "(= offset_one (+ 1 (* x offset_three)))")
    prover.prove("series argument perturbation has an integrable bound",
        "x y u denominator magnitude",
        """
        (<= 0 u) (<= u 1) (<= (- (/ 1 2)) x) (<= x (/ 1 2))
        (<= (- (/ 1 2)) y) (<= y (/ 1 2))
        (= denominator (* (- 1 (* x u u)) (- 1 (* y u u))))
        (= magnitude (ite (>= x y) (- x y) (- y x)))
        """,
        """
        (and (>= denominator (/ 1 4))
             (<= (* magnitude u u) (* 4 magnitude u u denominator)))
        """)
    prover.prove("series padding covers midpoint argument uncertainty",
        "x midpoint lo hi",
        "(<= lo x) (<= x hi) (<= lo midpoint) (<= midpoint hi)",
        "(and (<= (* 4 (- x midpoint)) (* 6 (- hi lo))) (<= (* 4 (- midpoint x)) (* 6 (- hi lo))))")
    prover.prove("zero-pole padding covers both possible signs of the second argument",
        "x bound",
        "(<= (- bound) x) (<= x bound)",
        "(and (<= (* 4 x) (* 6 bound)) (<= (* (- 4) x) (* 6 bound)))")


def compose_enclosure(prover):
    prover.prove("reciprocals reverse cap edges and preserve the reference cut",
        "left lo hi right inv_left inv_lo inv_hi inv_right",
        """
        (< 0 left) (<= left lo) (<= lo 1) (<= 1 hi) (<= hi right)
        (= (* left inv_left) 1) (= (* lo inv_lo) 1)
        (= (* hi inv_hi) 1) (= (* right inv_right) 1)
        """,
        "(and (<= inv_right inv_hi) (<= inv_hi 1) (<= 1 inv_lo) (<= inv_lo inv_left))")
    prover.prove("endpoint prices bound squared gaps on each side of the reference",
        "lo t hi g0 gt g1",
        """
        (<= 0 lo) (<= lo t) (<= t hi) (or (<= hi 1) (>= lo 1))
        (= g0 (- (* lo lo) 1)) (= gt (- (* t t) 1)) (= g1 (- (* hi hi) 1))
        """,
        """
        (and (=> (<= hi 1) (and (<= (* g1 g1) (* gt gt)) (<= (* gt gt) (* g0 g0))))
             (=> (>= lo 1) (and (<= (* g0 g0) (* gt gt)) (<= (* gt gt) (* g1 g1)))))
        """)
    prover.prove("fee-on-net transformation is monotone for valid rates",
        "lo f hi",
        "(>= lo 0) (<= lo f) (<= f hi) (< hi 1)",
        "(and (<= (* lo (- 1 f)) (* f (- 1 lo))) (<= (* f (- 1 hi)) (* hi (- 1 f))))")
    prover.prove("capped net-fee density is globally 45-Lipschitz in either coordinate",
        "k gap t f numerator t_power",
        """
        (>= k 0) (<= k 100) (>= gap 0) (<= (* k gap gap) (/ 1 10))
        (>= t 0) (<= (* t t) 2) (>= f 0) (<= (* 10 f) 1)
        (or (= t_power t) (= t_power (* t t t)))
        (= numerator (* 4 k gap t_power))
        """,
        "(< numerator (* 45 (- 1 f) (- 1 f)))")
    prover.prove("normalizing each endpoint shifts the entire interpolated path by at most two ulps",
        "start end true_start true_end lambda",
        """
        (<= 0 lambda) (<= lambda 1)
        (<= start true_start) (<= true_start (+ start 2))
        (<= end true_end) (<= true_end (+ end 2))
        """,
        """
        (let ((shift (+ (* (- 1 lambda) (- true_start start)) (* lambda (- true_end end)))))
          (and (<= 0 shift) (<= shift 2) (<= (* 45 shift) 90)))
        """)
    prover.prove("early capped branch stays outside the true cap edges",
        "lo hi start end true_start true_end left_cap right_cap",
        """
        (<= lo left_cap) (>= hi right_cap)
        (<= start true_start) (<= true_start (+ start 2))
        (<= end true_end) (<= true_end (+ end 2))
        """,
        "(and (=> (<= (+ end 2) lo) (<= true_end left_cap)) (=> (>= start hi) (>= true_start right_cap)))")
    prover.prove("weighted segment addition preserves the average enclosure",
        "lo hi previous wlo whi weight slo shi segment",
        """
        (<= lo previous) (<= previous hi)
        (<= 0 wlo) (<= wlo weight) (<= weight whi)
        (<= 0 slo) (<= slo segment) (<= segment shi)
        """,
        """
        (and (<= (+ lo (* wlo slo)) (+ previous (* weight segment)))
             (<= (+ previous (* weight segment)) (+ hi (* whi shi))))
        """)
    prover.prove("fee scaling and endpoint padding enclose the exact rounded-input fee",
        "lo hi normalized actual net base cap",
        """
        (<= lo normalized) (<= normalized hi)
        (<= (- normalized 90) actual) (<= actual (+ normalized 90))
        (<= 0 base) (<= base actual) (<= actual cap) (>= net 0)
        """,
        """
        (and (<= (* (ite (> (- lo 90) base) (- lo 90) base) net) (* actual net))
             (<= (* actual net) (* (ite (< (+ hi 90) cap) (+ hi 90) cap) net)))
        """)
    prover.prove("successful width guard bounds the upper overestimate given enclosure",
        "lo hi exact",
        f"(<= lo exact) (<= exact hi) (< (- hi lo) {Q // 4})",
        f"(and (<= 0 (- hi exact)) (< (- hi exact) {Q // 4}))")
    prover.prove("one ninth atom padding relates the rounded quote to the ideal net integral",
        "lo hi charged_exact ideal",
        f"(<= lo charged_exact) (<= charged_exact hi) (<= 0 (- charged_exact ideal)) (< (* 9 (- charged_exact ideal)) {Q})",
        f"(and (<= (- lo (/ {Q} 9)) ideal) (<= ideal hi))")
    prover.prove("terminal atom ceiling preserves the conservative fee and bounds its error",
        "ideal rounded_exact upper charged",
        """
        (<= 0 (- rounded_exact ideal)) (< (* 9 (- rounded_exact ideal)) 1)
        (<= 0 (- upper rounded_exact)) (< (* 4 (- upper rounded_exact)) 1)
        (<= 0 (- charged upper)) (< (- charged upper) 1)
        """,
        "(and (<= ideal charged) (< (* 36 (- charged ideal)) 49))")


def prove_fee_enclosure(prover):
    interval_arithmetic(prover)
    integral_identity(prover)
    series_enclosure(prover)
    compose_enclosure(prover)
