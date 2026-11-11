"""Check finite-fold and execution-history induction with Z3 Spacer."""

U64 = 1 << 64


def prove_induction(prover):
    # For each token the exact principal is rational and fee claims are
    # integral Q128 amounts. Using Reals overapproximates both domains.
    variables = """
    (declare-var p Real) (declare-var f Real) (declare-var pp Real) (declare-var ff Real)
    (declare-var dp Real) (declare-var df Real)
    (declare-var a Real) (declare-var b Real) (declare-var c Real) (declare-var d Real)
    (declare-var e Real) (declare-var g Real)
    """
    # Each singleton is an observed position change and its allocated
    # principal/fee allowance. The local delta and allocation lemmas prove
    # the singleton hypotheses for each Move transition.
    fold = """
    (declare-rel Fold (Real Real Real Real Real Real))
    (rule (Fold 0.0 0.0 0.0 0.0 0.0 0.0))
    (rule (=> (and (Fold p f pp ff dp df)
                   (>= a 0) (>= b 0) (>= c 0) (>= d 0)
                   (<= (- c a) e) (<= (- d b) g))
              (Fold (+ p a) (+ f b) (+ pp c) (+ ff d) (+ dp e) (+ df g))))
    """
    prover.fixedpoint("every finite position fold respects both allocated backing changes",
        variables + fold + """
        (declare-rel Bad ())
        (rule (=> (and (Fold p f pp ff dp df) (or (> (- pp p) dp) (> (- ff f) df))) Bad))
        (query Bad)
        """)
    # The same relation models virtual custody during a swap, in units
    # scaled to Q128 on the fee side. Settlement converts pending transfers
    # to actual balances with a nonnegative correction from output flooring.
    history = """
    (declare-var r Real) (declare-var v Real) (declare-var rr Real) (declare-var vv Real)
    (declare-rel Reach (Real Real Real Real))
    (rule (Reach 0.0 0.0 0.0 0.0))
    (rule (=> (and (Reach r v p f) (Fold p f pp ff dp df)
                   (>= (- rr r) dp) (>= (- vv v) df))
              (Reach rr vv pp ff)))
    """
    prover.fixedpoint("joint backing holds for all finite position sets and all finite ledger histories",
        variables + fold + history + """
        (declare-rel Bad ())
        (rule (=> (and (Reach r v p f) (or (> p r) (> f v))) Bad))
        (query Bad)
        """)
    prover.fixedpoint("the aggregate induction permits histories with nonzero liabilities",
        variables + fold + history + """
        (declare-rel Example ())
        (rule (=> (Reach 5.0 7.0 3.0 4.0) Example))
        (query Example)
        """, expected=1)


def prove_abort_boundary(prover):
    prover.prove("an empty pool can pass begin guards and still fail the execute output condition",
        "minimum maximum spot limit payment active ticks steps cap spent output",
        """
        (<= minimum spot) (< spot limit) (< limit maximum) (> payment 0)
        (= active 0) (= ticks 0) (= steps 1) (= spent 0) (= output 0)
        """,
        "(not (or (> output 0) (and (= steps cap) (< 0 spent) (not (= spot limit)))))",
        logic="QF_LIA")
    prover.prove("settlement's available input, backed debit and headroom cover its balance arithmetic",
        "payment other reserve_in reserve_out vault spent fee output",
        f"""
        (<= 0 fee) (<= fee spent) (<= spent payment) (< payment {U64})
        (<= 0 output) (<= output reserve_out) (< reserve_out {U64})
        (<= 0 reserve_in) (<= 0 vault) (<= 0 other)
        (< (+ reserve_in (- spent fee)) {U64}) (< (+ vault fee) {U64})
        (< (+ other output) {U64})
        """,
        f"""
        (and (<= 0 (- payment fee)) (<= 0 (- spent fee))
             (<= (- spent fee) (- payment fee)) (<= 0 (- payment spent))
             (<= 0 (- reserve_out output))
             (< (+ reserve_in (- spent fee)) {U64})
             (< (+ vault fee) {U64}) (< (+ other output) {U64}))
        """, logic="QF_LIA")
    prover.prove("a backed positive output and valid spend can still exceed output join headroom",
        "payment other reserve_out spent fee output",
        f"""
        (<= 0 fee) (<= fee spent) (<= spent payment) (< payment {U64})
        (<= 0 other) (< other {U64}) (< reserve_out {U64})
        (< 0 output) (<= output reserve_out)
        (>= (+ other output) {U64})
        """,
        f"(not (< (+ other output) {U64}))", logic="QF_LIA")
    prover.prove("a per-token aggregate supply bound implies all settlement joins fit",
        "payment other reserve_in reserve_out vault spent fee output",
        f"""
        (<= 0 fee) (<= fee spent) (<= spent payment)
        (<= 0 output) (<= output reserve_out)
        (<= 0 reserve_in) (<= 0 vault) (<= 0 other)
        (< (+ reserve_in vault payment) {U64})
        (< (+ reserve_out other) {U64})
        """,
        f"""
        (and (< (+ reserve_in (- spent fee)) {U64}) (< (+ vault fee) {U64})
             (< (+ other output) {U64}))
        """, logic="QF_LIA")


def prove_position_keys(prover):
    # Pool tag zero here represents absence, independently of how Sui encodes IDs.
    # Each array's key is an object UID, and owner is deliberately absent.
    prover.prove("fresh position creation inserts exactly one zero-stake row in its bound pool",
        "key arbitrary pool",
        """
        (> pool 0) (= (select pools key) 0) (= (select allocated key) 0)
        (= pools_after (store pools key pool)) (= stake_after (store stake key 0))
        (= allocated_after (store allocated key 1))
        """,
        """
        (and (= (select pools_after key) pool) (= (select stake_after key) 0)
             (= (select allocated_after key) 1)
             (=> (distinct arbitrary key)
                 (and (= (select pools_after arbitrary) (select pools arbitrary))
                      (= (select stake_after arbitrary) (select stake arbitrary))
                      (= (select allocated_after arbitrary) (select allocated arbitrary)))))
        """, logic="QF_AUFLIA", arrays=("pools", "pools_after", "stake", "stake_after",
                                        "allocated", "allocated_after"))
    prover.prove("a consumed liquidity request can update only its bound pool and position",
        "request_key request_pool key pool arbitrary new_stake new_checkpoint new_owed",
        """
        (> request_pool 0) (= (select pools request_key) request_pool)
        (= pool request_pool) (= key request_key) (>= new_stake 0)
        (>= new_checkpoint 0) (>= new_owed 0)
        (= stake_after (store stake key new_stake))
        (= checkpoint_after (store checkpoint key new_checkpoint))
        (= owed_after (store owed key new_owed))
        """,
        """
        (and (= (select pools key) pool) (= (select stake_after key) new_stake)
             (= (select checkpoint_after key) new_checkpoint) (= (select owed_after key) new_owed)
             (=> (or (distinct arbitrary request_key) (distinct (select pools arbitrary) pool))
                 (and (= (select stake_after arbitrary) (select stake arbitrary))
                      (= (select checkpoint_after arbitrary) (select checkpoint arbitrary))
                      (= (select owed_after arbitrary) (select owed arbitrary)))))
        """, logic="QF_AUFLIA", arrays=("pools", "stake", "stake_after", "checkpoint",
                                        "checkpoint_after", "owed", "owed_after"))
    prover.prove("destroying an empty position removes only its own pool membership",
        "key arbitrary pool",
        """
        (> pool 0) (= (select pools key) pool) (= (select stake key) 0)
        (= pools_after (store pools key 0))
        """,
        """
        (and (= (select pools_after key) 0)
             (=> (distinct arbitrary key) (= (select pools_after arbitrary) (select pools arbitrary))))
        """, logic="QF_AUFLIA", arrays=("pools", "pools_after", "stake"))

    # Check projection at an arbitrary UID across any finite trace. Live
    # values (including wrapped values) are counted by Pack minus Unpack.
    # Transfer, wrap, freeze, mutations and rollback preserve that count.
    # Runtime fresh UID allocation forbids reusing a UID even after Unpack.
    prover.fixedpoint("live Move position multiplicity equals ledger membership at every UID",
        """
        (declare-var uid Int) (declare-var other Int)
        (declare-var used Int) (declare-var live Int) (declare-var tag Int)
        (declare-rel Trace (Int Int Int Int))
        (rule (Trace uid 0 0 0))
        (rule (=> (and (Trace uid used live 0) (= used 0) (> tag 0)) (Trace uid 1 (+ live 1) tag)))
        (rule (=> (and (Trace uid used live tag) (> live 0)) (Trace uid used (- live 1) 0)))
        (rule (=> (and (Trace uid used live tag) (distinct other uid)) (Trace uid used live tag)))
        (declare-rel Bad ())
        (rule (=> (and (Trace uid used live tag)
                       (or (< live 0) (> live 1)
                           (and (= live 0) (distinct tag 0))
                           (and (= live 1) (or (<= tag 0) (distinct used 1)))))
                  Bad))
        (query Bad)
        """)

    # Enumerate the finite set of distinct UIDs with the pool's tag. A
    # successful one-row transition changes only its own contribution, while
    # creation or removal uses a zero contribution on the absent side.
    prover.fixedpoint("folding any finite UID set charges a local position transition only once",
        """
        (declare-var seen Int) (declare-var id Int) (declare-var target Int)
        (declare-var before Real) (declare-var after Real)
        (declare-var prior Real) (declare-var next Real)
        (declare-var change Real)
        (declare-rel Rows (Int Real Int Real Real))
        (rule (Rows target change 0 0.0 0.0))
        (rule (=> (and (Rows target change seen before after) (distinct id target) (= prior next))
                  (Rows target change seen (+ before prior) (+ after next))))
        (rule (=> (and (Rows target change 0 before after) (= (- next prior) change))
                  (Rows target change 1 (+ before prior) (+ after next))))
        (declare-rel Bad ())
        (rule (=> (and (Rows target change seen before after)
                       (or (and (= seen 0) (distinct before after))
                           (and (= seen 1) (distinct (- after before) change))))
                  Bad))
        (query Bad)
        """)
