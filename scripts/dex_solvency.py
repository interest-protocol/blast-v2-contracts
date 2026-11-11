"""Inductive principal and fee backing lemmas for the source-pinned DEX model."""

import re

from dex_price_bytecode import check_compiled_prices

Q128 = 1 << 128
U64 = 1 << 64
U256 = 1 << 256


def check_tick_prices(source, module=None):
    """Evaluate the pinned Q96 tick arithmetic at every legal index."""
    constants = (source / "lib/constants.move").read_text()
    table = (source / "curve/tick_math.move").read_text()

    def constant(name):
        match = re.search(rf"fun {name}\(\): u\d+ \{{\s*([0-9_]+)\s*\}}", constants)
        return int(match[1].replace("_", ""))

    factors = [int(value, 16) for value in re.findall(r"0x[0-9a-f]+", table)]
    offset = constant("max_tick")
    if module is not None:
        compiled_factors = check_compiled_prices(module, offset)
        if compiled_factors != tuple(factors):
            raise SystemExit("Compiled tick factors differ from the source model.")
        factors = compiled_factors
    if len(factors) != offset.bit_length():
        raise SystemExit("Tick factors do not cover the admitted magnitude.")
    low = constant("min_sqrt_price_x96")
    high = constant("max_sqrt_price_x96")
    if low < 1 << 32 or high >= 1 << 160:
        raise SystemExit("Tick endpoints are outside the proved mul_div caller domain.")
    previous = 0
    for index in range(2 * offset + 1):
        magnitude = abs(index - offset)
        ratio = Q128
        while magnitude:
            bit = magnitude & -magnitude
            magnitude -= bit
            product = ratio * factors[bit.bit_length() - 1]
            if product >= U256:
                raise SystemExit(f"Tick factor product overflows at index {index}.")
            ratio = product >> 128
        if ratio == 0:
            raise SystemExit(f"Tick ratio is zero at index {index}.")
        if index > offset:
            ratio = (U256 - 1) // ratio
        quotient, remainder = divmod(ratio, 1 << 32)
        price = quotient + (remainder != 0)
        if price <= previous or (index == 0 and price != low) or (index == 2 * offset and price != high):
            raise SystemExit(f"Tick price order or endpoint is invalid at index {index}.")
        previous = price
    print(f"PASS strict price order and endpoint constants at all {2 * offset + 1:,} tick indexes", flush=True)


def prove_principal(prover):
    prover.prove("positive Q96 prices and their negative reciprocals have the same ordering",
        "a b inv_a inv_b",
        "(> a 0) (> b 0) (= (* a inv_a) -1) (= (* b inv_b) -1) (< a b)",
        "(< inv_a inv_b)", logic="QF_NRA")
    prover.prove("floor-index bisection retains the floor and shrinks either search branch",
        "lo hi mid floor price_at_mid spot",
        """
        (<= lo floor) (<= floor hi) (< lo hi)
        (= mid (+ lo (div (+ (- hi lo) 1) 2)))
        (= (<= price_at_mid spot) (<= mid floor))
        """,
        """
        (and (=> (<= price_at_mid spot) (and (<= mid floor) (< (- hi mid) (- hi lo))))
             (=> (> price_at_mid spot) (and (<= floor (- mid 1)) (< (- mid 1 lo) (- hi lo)))))
        """, logic="QF_LIA")
    prover.prove("pool creation establishes a cursor below the top tick and brackets its spot",
        "index last grid_low grid_last grid_index grid_next spot",
        """
        (< 0 last) (<= grid_low spot) (< spot grid_last)
        (<= 0 index) (<= index last) (<= grid_index spot)
        (or (= index last) (< spot grid_next))
        (=> (= index last) (= grid_index grid_last))
        """,
        "(and (< index last) (<= grid_index spot) (< spot grid_next))", logic="QF_LIA")
    prover.prove("admitted swap limits keep the zero and top indexes from crossing",
        "min_price max_price spot limit end up",
        """
        (< min_price limit) (< limit max_price)
        (<= min_price spot) (< spot max_price)
        (or (= up 0) (= up 1))
        (=> (= up 1) (and (<= spot end) (<= end limit)))
        (=> (= up 0) (and (<= limit end) (<= end spot)))
        """,
        """
        (and (<= min_price end) (< end max_price)
            (=> (= up 0) (< min_price end)))
        """, logic="QF_LIA")
    prover.prove("an upward interior cursor cannot land on the initialized neighbor",
        "cursor neighbor next_cursor spot next_cursor_price neighbor_price",
        """
        (< cursor neighbor) (<= cursor next_cursor) (<= next_cursor neighbor)
        (<= next_cursor_price spot) (< spot neighbor_price)
        (=> (= next_cursor neighbor) (= next_cursor_price neighbor_price))
        """,
        "(and (<= cursor next_cursor) (< next_cursor neighbor))", logic="QF_LIA")
    prover.prove("an interior cursor change leaves every initialized endpoint on its original side",
        "old new neighbor endpoint up",
        """
        (or (= up 0) (= up 1))
        (=> (= up 1) (and (<= old new) (< new neighbor)
            (or (<= endpoint old) (<= neighbor endpoint))))
        (=> (= up 0) (and (<= neighbor new) (<= new old)
            (or (<= endpoint neighbor) (< old endpoint))))
        """,
        "(= (<= endpoint old) (<= endpoint new))", logic="QF_LIA")
    prover.prove("a bracket-capped interior cursor still bounds the spot",
        "index upper spot price next_price old_spot old_next up neighbor_present",
        """
        (<= index upper) (<= price spot)
        (=> (< index upper) (< spot next_price))
        (=> (and (= index upper) (= up 0))
            (and (<= spot old_spot) (<= old_spot old_next) (= old_next next_price)))
        (=> (and (= up 1) (= neighbor_present 1)) (< index upper))
        (=> (and (= index upper) (= up 1) (= neighbor_present 0)) (<= spot next_price))
        (or (= up 0) (= up 1)) (or (= neighbor_present 0) (= neighbor_present 1))
        """,
        "(and (<= price spot) (<= spot next_price))", logic="QF_LIA")
    prover.prove("either crossing produces the correct cursor at the exact tick price",
        "tick cursor spot below at above up",
        """
        (< below at) (< at above) (= spot at)
        (or (= up 0) (= up 1))
        (= cursor (ite (= up 1) tick (- tick 1)))
        """,
        """
        (and (=> (= up 1) (and (= cursor tick) (<= at spot) (<= spot above)))
             (=> (= up 0) (and (= (+ cursor 1) tick) (<= below spot) (<= spot at))))
        """, logic="QF_LIA")
    prover.prove("compiled nested asset floors imply the exact principal lower bound",
        "numerator upper lower first result",
        """
        (>= numerator 0) (>= upper 1) (>= lower 1)
        (<= (* first upper) numerator) (< numerator (* (+ first 1) upper))
        (<= (* result lower) first) (< first (* (+ result 1) lower))
        (<= (+ first 1) (* (+ result 1) lower))
        """,
        "(and (<= (* result lower upper) numerator) (< numerator (* (+ result 1) lower upper)))")
    prover.prove("the two Q64 asset output floors preserve the exact principal lower bound",
        "numerator upper lower first output",
        f"""
        (>= numerator 0) (>= upper 1) (>= lower 1)
        (<= (* first upper) numerator)
        (<= (* output lower) (* first {1 << 64}))
        """,
        f"(<= (* output lower upper) (* numerator {1 << 64}))")
    # For quote use the Q96 price coordinate. For asset use the increasing
    # coordinate -1/price, with the Q96 conversion included in the units.
    # Both coordinates commute with clamp. Their opposite signs in the two
    # claims are accounted for by the directional balance update below.
    prover.prove("clamped range changes by exactly the step distance for active stake",
        "lo hi start end active before after",
        """
        (< lo hi) (<= start end)
        (or (<= hi start) (<= end lo) (and (<= lo start) (<= end hi)))
        (= active (ite (and (<= lo start) (<= end hi)) 1 0))
        (= before (ite (< start lo) lo (ite (> start hi) hi start)))
        (= after (ite (< end lo) lo (ite (> end hi) hi end)))
        """,
        "(= (- after before) (* active (- end start)))")
    prover.prove("nearest upward endpoint rules out a position boundary inside a priced step",
        "lo hi cursor next",
        """
        (< lo hi) (< cursor next)
        (or (<= lo cursor) (>= lo next))
        (or (<= hi cursor) (>= hi next))
        """,
        """
        (and (or (<= hi cursor) (>= lo next) (and (<= lo cursor) (>= hi next)))
             (= (and (<= lo cursor) (< cursor hi)) (and (<= lo cursor) (>= hi next))))
        """, logic="QF_LIA")
    prover.prove("nearest downward endpoint rules out a position boundary inside a priced step",
        "lo hi cursor next",
        """
        (< lo hi) (<= next cursor)
        (or (< cursor lo) (<= lo next))
        (or (< cursor hi) (<= hi next))
        """,
        """
        (and (or (<= hi next) (< cursor lo) (and (<= lo next) (< cursor hi)))
             (= (and (<= lo cursor) (< cursor hi)) (and (<= lo next) (< cursor hi))))
        """, logic="QF_LIA")
    prover.prove("a position enters or leaves active liquidity exactly at its own endpoint",
        "lo hi crossing stake",
        "(<= 0 lo) (< lo hi) (> crossing 0) (>= stake 0)",
        """
        (let ((before (ite (and (< lo crossing) (<= crossing hi)) stake 0))
              (after (ite (and (<= lo crossing) (< crossing hi)) stake 0))
              (starts (ite (= lo crossing) stake 0))
              (ends (ite (= hi crossing) stake 0)))
          (and (= (+ after ends) (+ before starts)) (<= ends before) (<= starts after)))
        """, logic="QF_LIA")
    prover.prove("pointwise endpoint changes compose into aggregate active liquidity",
        "before after starts ends position_before position_after position_starts position_ends",
        """
        (= (+ after ends) (+ before starts))
        (= (+ position_after position_ends) (+ position_before position_starts))
        """,
        """
        (= (+ after position_after ends position_ends)
           (+ before position_before starts position_starts))
        """, logic="QF_LIA")
    prover.prove("moving inside a range preserves a position's active membership",
        "lo hi cursor after",
        """
        (< lo hi)
        (or (and (<= lo cursor) (<= lo after)) (and (< cursor lo) (< after lo)))
        (or (and (<= hi cursor) (<= hi after)) (and (< cursor hi) (< after hi)))
        """,
        "(= (and (<= lo cursor) (< cursor hi)) (and (<= lo after) (< after hi)))",
        logic="QF_LIA")
    prover.prove("principal delta folds over an arbitrary finite position list",
        "active_prefix active_added delta_prefix weight step",
        """
        (>= weight 0) (>= step 0) (>= active_prefix 0)
        (or (= active_added 0) (= active_added weight))
        (= delta_prefix (* active_prefix step))
        """,
        "(= (+ delta_prefix (* active_added step)) (* (+ active_prefix active_added) step))")
    prover.prove("a no-price crossing or an empty interval changes neither principal obligation",
        "active step",
        "(>= active 0) (>= step 0) (or (= active 0) (= step 0))",
        "(= (* active step) 0)")
    prover.prove("principal mint preserves backing at the clamped spot",
        "reserve claims per_unit old delta payment",
        """
        (>= per_unit 0) (>= old 0) (>= delta 0)
        (>= claims (* per_unit old)) (>= reserve claims)
        (>= payment (* per_unit delta))
        """,
        "(>= (+ reserve payment) (+ (- claims (* per_unit old)) (* per_unit (+ old delta))))")
    prover.prove("principal burn is payable and preserves backing at the clamped spot",
        "reserve claims per_unit old delta payment",
        """
        (>= per_unit 0) (<= 0 delta) (<= delta old)
        (>= claims (* per_unit old)) (>= reserve claims)
        (<= 0 payment) (<= payment (* per_unit delta))
        """,
        """
        (and (<= payment reserve)
             (>= (- reserve payment) (+ (- claims (* per_unit old)) (* per_unit (- old delta)))))
        """)
    prover.prove("accumulated swap transfers preserve both principal inequalities",
        "reserve_in reserve_out claims_in claims_out increase decrease net output",
        """
        (>= claims_in 0) (>= claims_out 0) (>= reserve_in claims_in) (>= reserve_out claims_out)
        (>= increase 0) (>= decrease 0) (<= decrease claims_out)
        (>= net increase) (<= 0 output) (<= output decrease)
        """,
        """
        (and (<= output reserve_out) (>= (+ reserve_in net) (+ claims_in increase))
             (>= (- reserve_out output) (- claims_out decrease)))
        """)
    prover.prove("each priced interval preserves accumulated input and output rounding",
        "net exact_in output_x64 exact_out net_step input_step output_step exact_step",
        """
        (>= net exact_in) (>= net_step input_step)
        (<= output_x64 exact_out) (<= output_step exact_step)
        """,
        "(and (>= (+ net net_step) (+ exact_in input_step))"
        "     (<= (+ output_x64 output_step) (+ exact_out exact_step)))")


def prove_fee_backing(prover):
    prover.prove("a live position retains both initialized endpoints",
        "stake lo_starts lo_ends hi_starts hi_ends",
        """
        (> stake 0) (>= lo_starts stake) (>= hi_ends stake)
        (>= lo_ends 0) (>= hi_starts 0)
        """,
        "(and (> (+ lo_starts lo_ends) 0) (> (+ hi_starts hi_ends) 0))",
        logic="QF_LIA")
    prover.prove("unbounded inside growth changes only for the active cohort",
        "global lower_out upper_out inc active below",
        "(>= inc 0) (or (= active 0) (= active 1))",
        """
        (let ((before (ite (= active 1) (- global lower_out upper_out)
                          (ite (= below 1) (- lower_out upper_out) (- upper_out lower_out))))
              (after (ite (= active 1) (- (+ global inc) lower_out upper_out)
                         (ite (= below 1) (- lower_out upper_out) (- upper_out lower_out)))))
          (= (- after before) (* active inc)))
        """, logic="QF_LIA")
    prover.prove("unbounded inside growth is continuous through either endpoint flip",
        "global lower_out upper_out",
        "true",
        """
        (and (= (- lower_out upper_out) (- global (- global lower_out) upper_out))
             (= (- upper_out lower_out) (- global lower_out (- global upper_out))))
        """, logic="QF_LIA")
    # Split pairwise subtraction from the expression trees for inside growth.
    # Repeated application handles global - lower - upper and then checkpoint.
    prover.prove("stored wrapping subtraction commutes with integer lifts",
        "left right",
        "true",
        f"(= (mod (- (mod left {U256}) (mod right {U256})) {U256}) (mod (- left right) {U256}))",
        logic="QF_LIA")
    prover.prove("credit fold allocates growth against the pre-cross active liquidity",
        "inc prefix next_weight prefix_claim",
        "(>= inc 0) (>= prefix 0) (>= next_weight 0) (= prefix_claim (* inc prefix))",
        "(= (+ prefix_claim (* inc next_weight)) (* inc (+ prefix next_weight)))")
    prover.prove("the actual integer credit quotient fits and cannot allocate more than funding",
        "funded liquidity",
        f"(<= 0 funded) (< funded {U64}) (<= 1 liquidity) (< liquidity {Q128})",
        f"""
        (let ((scaled (* funded {Q128})))
          (let ((increment (div scaled liquidity)))
            (and (<= 0 increment) (< increment {1 << 192})
                 (<= (* increment liquidity) scaled))))
        """, logic="QF_NIA")
    prover.prove("funding every credit preserves aggregate Q128 fee backing",
        "vault pending claims funded new_claims",
        f"""
        (>= vault 0) (>= pending 0) (>= funded 0)
        (>= claims 0) (<= claims (* (+ vault pending) {Q128}))
        (<= 0 new_claims) (<= new_claims (* funded {Q128}))
        """,
        f"(<= (+ claims new_claims) (* (+ vault pending funded) {Q128}))", logic="QF_LIA")
    prover.prove("settlement replaces pending fee funding with actual vault custody",
        "vault pending claims after",
        f"""
        (>= vault 0) (>= pending 0) (>= claims 0)
        (<= claims (* (+ vault pending) {Q128})) (= after (+ vault pending)) (< after {U64})
        """,
        f"(and (<= claims (* after {Q128})) (< claims {1 << 192}))", logic="QF_LIA")
    prover.prove("backing implies the true growth delta and accrued product fit before checkpointing",
        "vault claims owed growth_delta stake",
        f"""
        (>= vault 0) (< vault {U64}) (<= claims (* vault {Q128}))
        (>= owed 0) (>= growth_delta 0) (>= stake 1)
        (<= (+ owed (* growth_delta stake)) claims)
        """,
        f"""(and (< growth_delta {1 << 192}) (< (* growth_delta stake) {1 << 192})
                 (< (+ owed (* growth_delta stake)) {1 << 192})
                 (< (+ owed (* growth_delta stake)) {U256}))""")
    prover.prove("a backed true growth delta is recovered exactly by wrapping subtraction",
        "inside checkpoint delta",
        f"(= delta (- inside checkpoint)) (<= 0 delta) (< delta {1 << 192})",
        f"(= (mod (- (mod inside {U256}) (mod checkpoint {U256})) {U256}) delta)",
        logic="QF_LIA")
    prover.prove("checkpoint then restake preserves the full claim without historical accrual",
        "owed growth_delta old_stake new_stake checkpoint inside after_owed after_checkpoint",
        """
        (>= owed 0) (>= growth_delta 0) (>= old_stake 0) (>= new_stake 0)
        (= growth_delta (- inside checkpoint))
        (= after_owed (+ owed (* growth_delta old_stake)))
        (= after_checkpoint inside)
        """,
        """
        (= (+ after_owed (* (- inside after_checkpoint) new_stake))
           (+ owed (* growth_delta old_stake)))
        """)
    prover.prove("fee collection is payable and preserves backing with or without fractional dust",
        "vault claims position payout remainder next_owed",
        f"""
        (>= vault 0) (< vault {U64}) (<= 0 position) (<= position claims)
        (<= claims (* vault {Q128}))
        (= payout (div position {Q128})) (= remainder (mod position {Q128}))
        (or (= next_owed 0) (= next_owed remainder))
        """,
        f"""
        (and (<= 0 payout) (<= payout vault) (< payout {U64})
             (<= (+ (- claims position) next_owed) (* (- vault payout) {Q128})))
        """, logic="QF_LIA")


def prove_solvency(prover):
    prove_principal(prover)
    prove_fee_backing(prover)
    prove_joint_induction(prover)


def prove_joint_induction(prover):
    """Compose the finite-fold lemmas at the actual custody boundaries."""
    # Run once per token. The priced-step signs pick which token is input.
    # Margins let the loop relate claims to pending transfers without
    # pretending the balances have already been updated.
    prover.prove("pool backing starts with zero reserve and fee liabilities",
        "reserve principal vault liability",
        "(= reserve 0) (= principal 0) (= vault 0) (= liability 0)",
        f"(and (>= reserve principal) (>= (* vault {Q128}) liability))",
        logic="QF_LIA")
    prover.prove("the joint backing invariant survives each priced step before settlement",
        "reserve principal vault liability pending_principal pending_fee principal_change net output fee allocated side",
        f"""
        (>= (+ reserve pending_principal) principal)
        (>= (* (+ vault pending_fee) {Q128}) liability)
        (>= principal 0) (>= (+ principal principal_change) 0)
        (>= net 0) (>= output 0) (>= fee 0)
        (<= 0 allocated) (<= allocated (* fee {Q128}))
        (or (= side 0) (= side 1))
        (=> (= side 1) (and (<= 0 principal_change) (<= principal_change net)))
        (=> (= side 0) (and (<= principal_change 0) (<= output (- principal_change))
                            (= fee 0) (= allocated 0)))
        """,
        f"""
        (and (>= (+ reserve pending_principal (ite (= side 1) net (- output)))
                 (+ principal principal_change))
             (>= (* (+ vault pending_fee fee) {Q128}) (+ liability allocated)))
        """, logic="QF_NRA")
    prover.prove("the joint backing invariant survives signed settlement and output rounding",
        "reserve principal vault liability pending_net pending_output pending_fee after_reserve after_vault side output",
        f"""
        (>= principal 0) (>= liability 0) (>= reserve 0)
        (>= pending_net 0) (>= pending_output 0) (>= pending_fee 0)
        (<= 0 output) (<= output pending_output)
        (or (= side 0) (= side 1))
        (>= (+ reserve (ite (= side 1) pending_net (- pending_output))) principal)
        (>= (* (+ vault pending_fee) {Q128}) liability)
        (= after_reserve (+ reserve (ite (= side 1) pending_net (- output))))
        (= after_vault (+ vault pending_fee))
        """,
        f"""(and (>= after_reserve principal) (>= (* after_vault {Q128}) liability)
                 (=> (= side 0) (<= output reserve)))""", logic="QF_NRA")
    prover.prove("the joint backing invariant survives mint, burn, donation and empty-position transitions",
        "reserve principal vault liability principal_delta reserve_delta liability_delta vault_delta operation",
        f"""
        (>= reserve principal) (>= (* vault {Q128}) liability)
        (or
            (and (= operation 0) (<= 0 principal_delta) (<= principal_delta reserve_delta)
                 (= liability_delta 0) (= vault_delta 0))
            (and (= operation 1) (<= principal_delta reserve_delta) (<= reserve_delta 0)
                 (<= liability_delta (* vault_delta {Q128})) (<= vault_delta 0))
            (and (= operation 2) (= principal_delta 0) (= reserve_delta 0)
                 (<= 0 liability_delta) (<= liability_delta (* vault_delta {Q128})))
            (and (= operation 3) (= principal_delta 0) (= reserve_delta 0)
                 (= liability_delta 0) (= vault_delta 0)))
        """,
        f"""
        (and (>= (+ reserve reserve_delta) (+ principal principal_delta))
             (>= (* (+ vault vault_delta) {Q128}) (+ liability liability_delta)))
        """, logic="QF_NRA")
