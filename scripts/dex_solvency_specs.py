"""Sui Prover contracts for the production custody transitions."""

CURVE_CUSTODY_SUMMARIES = """\
#[mode(spec), ext(spec_only, no_abort)]
public(package) fun custody_growth(self: &Curve): Growth { self.growth }

#[mode(spec), ext(spec_only, no_abort)]
public(package) fun credited_custody_growth(
    old: Growth, liquidity: u128, asset: u64, quote: u64,
): Growth {
    if (liquidity > 0) Growth {
        asset: wrapping_add(old.asset, ((asset as u256) << 128) / (liquidity as u256)),
        quote: wrapping_add(old.quote, ((quote as u256) << 128) / (liquidity as u256)),
    } else old
}

// The liquidity proof checks the mutation of the two mutable arguments.
#[mode(spec), ext(spec(target = change_liquidity, ignore_abort))]
fun change_liquidity_for_custody(
    self: &mut Curve, fees: &mut PositionFees, lower: u32, upper: u32, old: u128, delta: u128, add: bool,
) {
    change_liquidity(self, fees, lower, upper, old, delta, add)
}

// Custody only needs the representation bounds. The fee collection contract
// and Z3's shift lemma separately establish the quotient and remainder.
#[mode(spec), ext(spec(target = take_fees, ignore_abort))]
fun take_fees_for_custody(self: &mut PositionFees, full_exit: bool): (u64, u64) {
    let (asset, quote) = take_fees(self, full_exit);
    prover::prover::ensures(asset >= 0 && quote >= 0);
    (asset, quote)
}

#[mode(spec), ext(spec(target = new, ignore_abort))]
fun new_curve_for_custody(price_x96: u256, ctx: &mut TxContext): Curve {
    new(price_x96, ctx)
}

"""

CUSTODY_EVENTS = """\
#[mode(spec), ext(spec(target = liquidity_added, ignore_abort))]
fun added_for_custody(
    pool_id: ID, position_id: ID, tick_lower: I32, tick_upper: I32, liquidity: u128,
    asset_amount: u64, quote_amount: u64,
) {
    liquidity_added(pool_id, position_id, tick_lower, tick_upper, liquidity, asset_amount, quote_amount)
}

#[mode(spec), ext(spec(target = liquidity_removed, ignore_abort))]
fun removed_for_custody(
    pool_id: ID, position_id: ID, tick_lower: I32, tick_upper: I32, liquidity: u128,
    asset_amount: u64, quote_amount: u64, asset_fee: u64, quote_fee: u64,
) {
    liquidity_removed(pool_id, position_id, tick_lower, tick_upper, liquidity,
        asset_amount, quote_amount, asset_fee, quote_fee)
}

#[mode(spec), ext(spec(target = donated, ignore_abort))]
fun donated_for_custody(pool_id: ID, asset_amount: u64, quote_amount: u64) {
    donated(pool_id, asset_amount, quote_amount)
}

"""

CUSTODY_SPECS = """\
#[mode(spec), ext(spec(target = sui::object::new, ignore_abort))]
fun new_uid_for_custody(ctx: &mut TxContext): UID {
    sui::object::new(ctx)
}

#[mode(spec), ext(spec(prove, target = new, ignore_abort,
    include(a = new_uid_for_custody, b = curve::new_curve_for_custody)))]
fun new_custody_spec<Asset, Quote>(
    package_version: &PackageVersion<BLAST_FUN_DEX>, tick_spacing: u32,
    lp_fee: LpFee, sqrt_price_x96: u256, ctx: &mut TxContext,
): PoolInitializer<Asset, Quote> {
    let result = new<Asset, Quote>(package_version, tick_spacing, lp_fee, sqrt_price_x96, ctx);
    prover::prover::ensures(result.pool.sqrt_price_x96 == sqrt_price_x96);
    prover::prover::ensures(sqrt_price_x96 >= constants::min_sqrt_price_x96!()
        && sqrt_price_x96 < constants::max_sqrt_price_x96!());
    prover::prover::ensures(result.pool.asset_reserve.value() == 0 && result.pool.quote_reserve.value() == 0);
    prover::prover::ensures(result.pool.asset_fees.value() == 0 && result.pool.quote_fees.value() == 0);
    result
}

#[mode(spec), ext(spec(prove, target = settle_add_liquidity, ignore_abort,
    include(a = curve::change_liquidity_for_custody, b = blast_events::added_for_custody)))]
fun mint_custody_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>, position: &mut Position<Asset, Quote>,
    liquidity: u128, asset_payment: Balance<Asset>, quote_payment: Balance<Quote>,
    asset_required: u64, quote_required: u64,
): Completion<Asset, Quote, AddLiquidity> {
    let asset_reserve = self.asset_reserve.value() as u128;
    let quote_reserve = self.quote_reserve.value() as u128;
    let asset_fees = self.asset_fees.value();
    let quote_fees = self.quote_fees.value();
    let price = self.sqrt_price_x96;
    let old = position.liquidity;
    let (lower, upper) = (position.tick_lower, position.tick_upper);
    let result = settle_add_liquidity(
        self, position, liquidity, asset_payment, quote_payment, asset_required, quote_required,
    );
    prover::prover::ensures((self.asset_reserve.value() as u128) == asset_reserve + (asset_required as u128));
    prover::prover::ensures((self.quote_reserve.value() as u128) == quote_reserve + (quote_required as u128));
    prover::prover::ensures(self.asset_fees.value() == asset_fees && self.quote_fees.value() == quote_fees);
    prover::prover::ensures(self.sqrt_price_x96 == price);
    prover::prover::ensures((position.liquidity as u256) == (old as u256) + (liquidity as u256));
    prover::prover::ensures(position.tick_lower == lower && position.tick_upper == upper);
    result
}

#[mode(spec), ext(spec(prove, target = settle_remove_liquidity, ignore_abort,
    include(a = curve::change_liquidity_for_custody, b = blast_events::removed_for_custody,
        c = curve::take_fees_for_custody)))]
fun burn_custody_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>, position: &mut Position<Asset, Quote>,
    liquidity: u128, asset_amount: u64, quote_amount: u64,
): Completion<Asset, Quote, RemoveLiquidity> {
    let asset_reserve = self.asset_reserve.value() as u128;
    let quote_reserve = self.quote_reserve.value() as u128;
    let asset_fees = self.asset_fees.value() as u128;
    let quote_fees = self.quote_fees.value() as u128;
    let price = self.sqrt_price_x96;
    let old = position.liquidity;
    let (lower, upper) = (position.tick_lower, position.tick_upper);
    let result = settle_remove_liquidity(self, position, liquidity, asset_amount, quote_amount);
    prover::prover::ensures((self.asset_reserve.value() as u128) + (asset_amount as u128) == asset_reserve);
    prover::prover::ensures((self.quote_reserve.value() as u128) + (quote_amount as u128) == quote_reserve);
    prover::prover::ensures((self.asset_fees.value() as u128) <= asset_fees);
    prover::prover::ensures((self.quote_fees.value() as u128) <= quote_fees);
    prover::prover::ensures((self.asset_fees.value() as u128) + (result.asset_output.value() as u128)
        == asset_fees + (asset_amount as u128));
    prover::prover::ensures((self.quote_fees.value() as u128) + (result.quote_output.value() as u128)
        == quote_fees + (quote_amount as u128));
    prover::prover::ensures(self.sqrt_price_x96 == price);
    prover::prover::ensures((position.liquidity as u256) + (liquidity as u256) == (old as u256));
    prover::prover::ensures(position.tick_lower == lower && position.tick_upper == upper);
    result
}

#[mode(spec), ext(spec(prove, target = execute_donate, ignore_abort,
    include(a = curve::credit_spec, b = blast_events::donated_for_custody)))]
fun donation_custody_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>, package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: DonateRequest<Asset, Quote>,
): Completion<Asset, Quote, Donate> {
    let asset_reserve = self.asset_reserve.value();
    let quote_reserve = self.quote_reserve.value();
    let asset_fees = self.asset_fees.value() as u128;
    let quote_fees = self.quote_fees.value() as u128;
    let asset_payment = request.asset_payment.value();
    let quote_payment = request.quote_payment.value();
    let liquidity = self.curve.liquidity();
    let growth = curve::custody_growth(&self.curve);
    let price = self.sqrt_price_x96;
    let result = execute_donate(self, package_version, request);
    prover::prover::ensures(liquidity > 0 && self.curve.liquidity() == liquidity);
    prover::prover::ensures(curve::custody_growth(&self.curve)
        == curve::credited_custody_growth(growth, liquidity, asset_payment, quote_payment));
    prover::prover::ensures(self.asset_reserve.value() == asset_reserve && self.quote_reserve.value() == quote_reserve);
    prover::prover::ensures((self.asset_fees.value() as u128) == asset_fees + (asset_payment as u128));
    prover::prover::ensures((self.quote_fees.value() as u128) == quote_fees + (quote_payment as u128));
    prover::prover::ensures(self.sqrt_price_x96 == price);
    prover::prover::ensures(result.asset_output.value() == 0 && result.quote_output.value() == 0);
    result
}

"""

FEE_FUNDING_SPECS = """\
#[mode(spec), ext(spec_only(loop_inv(target = swap_amounts)), no_abort)]
#[allow(unused_function)]
fun swap_fee_funding_invariant(
    total_fee: u64, asset_credited: u128, quote_credited: u128, is_asset_input: bool,
    remaining: u64, input_value: u64, net_total: u128,
): bool {
    total_fee >= 0 && net_total <= (input_value as u128)
        && (remaining as u128) + (total_fee as u128) + net_total == (input_value as u128)
        && asset_credited == (if (is_asset_input) total_fee as u128 else 0)
        && quote_credited == (if (is_asset_input) 0 else total_fee as u128)
}

#[mode(spec), ext(spec(prove, target = swap_amounts, ignore_abort, include(
    a = continuous_fee::swap_step_budget_spec,
    b = curve::next_tick_for_budget,
    c = curve::tick_price_for_budget,
    d = curve::credit_spec,
    e = curve::cross_spec,
    f = curve::move_inside_for_budget,
)))]
fun swap_fee_funding_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>, is_asset_input: bool, input_value: u64,
    sqrt_price_limit_x96: u256, fee_path: ContinuousPath, allow_zero_partial: bool,
): (u64, u64, u256, u64, u128, u128, u128, u256) {
    let (spent, output, spot, fee, asset_credited, quote_credited, net_total, output_x64) =
        swap_amounts(self, is_asset_input, input_value, sqrt_price_limit_x96, fee_path, allow_zero_partial);
    prover::prover::ensures(asset_credited == (if (is_asset_input) fee as u128 else 0));
    prover::prover::ensures(quote_credited == (if (is_asset_input) 0 else fee as u128));
    prover::prover::ensures(net_total <= (spent as u128));
    prover::prover::ensures(net_total > (spent as u128) || net_total + (fee as u128) == (spent as u128));
    prover::prover::ensures((output as u256) == output_x64 >> 64);
    (spent, output, spot, fee, asset_credited, quote_credited, net_total, output_x64)
}

"""


def instrument_swap_fee_funding(source):
    """Observe credit arguments, cumulative net input and output rounding."""
    edits = (
        ("let (input_spent, output_amount, sqrt_price_after_x96, lp_fee_amount) =\n"
         "        self.swap_amounts(",
         "let (input_spent, output_amount, sqrt_price_after_x96, lp_fee_amount, _, _, _, _) =\n"
         "        self.swap_amounts("),
        ("allow_zero_partial: bool,\n): (u64, u64, u256, u64) {\n    let up = !is_asset_input;",
         "allow_zero_partial: bool,\n): (u64, u64, u256, u64, u128, u128, u128, u256) {\n    let up = !is_asset_input;"),
        ("    let mut total_fee = 0;\n    let mut spot",
         "    let mut total_fee = 0;\n    let mut asset_credited = 0u128;\n    let mut quote_credited = 0u128;\n"
         "    let mut net_total = 0u128;\n    let mut spot"),
        ("            remaining = remaining - spent;",
         "            remaining = remaining - spent;\n"
         "            net_total = net_total + ((spent - fee) as u128);"),
        ("            if (is_asset_input) self.curve.credit(fee, 0)\n"
         "            else self.curve.credit(0, fee);",
         """            if (is_asset_input) {
                let asset = fee;
                let quote = 0;
                self.curve.credit(asset, quote);
                asset_credited = asset_credited + (asset as u128);
                quote_credited = quote_credited + (quote as u128);
            } else {
                let asset = 0;
                let quote = fee;
                self.curve.credit(asset, quote);
                asset_credited = asset_credited + (asset as u128);
                quote_credited = quote_credited + (quote as u128);
            };"""),
        ("(input_value - remaining, output as u64, spot, total_fee)",
         "(input_value - remaining, output as u64, spot, total_fee, asset_credited, quote_credited, net_total, output_x64)"),
    )
    for before, after in edits:
        if source.count(before) != 1:
            raise SystemExit("Could not locate the swap fee funding observation.")
        source = source.replace(before, after, 1)
    return source

# Reuse the verified settlement contracts. The observation records the exact
# pre-cast principal returned by pricing and the quantity passed to pricing.
LIQUIDITY_EXECUTION_SPECS = """
#[mode(spec), ext(spec(target = position_amounts, ignore_abort))]
fun amounts_for_execution<Asset, Quote>(
    self: &Pool<Asset, Quote>, position: &Position<Asset, Quote>,
    liquidity: u128, round_up: bool,
): (u256, u256) {
    position_amounts(self, position, liquidity, round_up)
}
"""


def liquidity_execution_specs():
    specs = [LIQUIDITY_EXECUTION_SPECS]
    for operation, action, settlement, up in (
        ("add", "Add", "mint", "true"), ("remove", "Remove", "burn", "false"),
    ):
        def delta(before, after, amount):
            if operation == "add":
                return f"{after} == {before} + {amount}"
            return f"{after} + {amount} == {before}"

        position = delta("before_stake", "(position.liquidity as u256)", "(stake as u256)")
        asset = delta("before_asset", "(self.asset_reserve.value() as u128)", "(asset as u128)")
        quote = delta("before_quote", "(self.quote_reserve.value() as u128)", "(quote as u128)")
        specs.append(f"""
#[mode(spec), ext(spec(prove, target = execute_{operation}_observed, ignore_abort,
    include(a = amounts_for_execution, b = {settlement}_custody_spec)))]
fun execute_{operation}_backing_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>, package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: {action}LiquidityRequest<Asset, Quote>, position: &mut Position<Asset, Quote>,
): (Completion<Asset, Quote, {action}Liquidity>, u256, u256, u128, bool) {{
    let before_asset = self.asset_reserve.value() as u128;
    let before_quote = self.quote_reserve.value() as u128;
    let before_price = self.sqrt_price_x96;
    let before_stake = position.liquidity as u256;
    let stake = request.liquidity;
    let (completion, asset, quote, observed_stake, up) =
        execute_{operation}_observed(self, package_version, request, position);
    prover::prover::ensures(stake == observed_stake && up == {up});
    let fits = asset <= (std::u64::max_value!() as u256) && quote <= (std::u64::max_value!() as u256);
    prover::prover::ensures(fits);
    prover::prover::ensures({position});
    prover::prover::ensures(!fits || ({asset} && {quote}));
    prover::prover::ensures(self.sqrt_price_x96 == before_price);
    (completion, asset, quote, observed_stake, up)
}}
""")
    return "".join(specs)


def instrument_liquidity_execution(source):
    """Observe production pricing and custody using private staged copies."""
    observations = (
        ("add", "Add", "asset_required", "quote_required", "true"),
        ("remove", "Remove", "asset_amount", "quote_amount", "false"),
    )
    for operation, action, asset, quote, up in observations:
        start = f"public fun execute_{operation}_liquidity<Asset, Quote>("
        head, sep, tail = source.partition(start)
        if not sep:
            raise SystemExit("Missing public liquidity execution target.")
        body, sep, rest = tail.partition("\n}\n")
        if not sep:
            raise SystemExit("Missing public liquidity execution body.")
        return_type = f"): Completion<Asset, Quote, {action}Liquidity> {{"
        price = f"let ({asset}, {quote}) = self.position_amounts(position, liquidity, {up});"
        settle = f"    self.settle_{operation}_liquidity("
        if any(body.count(marker) != 1 for marker in (return_type, price, settle)):
            raise SystemExit("Could not locate the liquidity execution observations.")
        # Keep existing callers and the observed code in the same proof package.
        wrapper = (
            body[:body.index(return_type) + len(return_type)]
            + f"\n    let (result, _, _, _, _) = self.execute_{operation}_observed("
            "package_version, request, position);\n    result\n}\n\n"
        )
        body = body.replace(
            return_type, f"): (Completion<Asset, Quote, {action}Liquidity>, u256, u256, u128, bool) {{",
        ).replace(price, "let up = " + up + ";\n    " + price.replace(f", {up})", ", up)"))
        body = body.replace(settle, settle.replace("self.", "let completion = self."))
        body = body.rstrip() + f";\n    (completion, {asset}, {quote}, liquidity, up)"
        observed = f"fun execute_{operation}_observed<Asset, Quote>("
        source = head + start + wrapper + observed + body + sep + rest
    return source

SWAP_SETTLEMENT_TOTAL = """\
#[mode(spec), ext(spec(prove, target = settle_swap, include = blast_events::swapped_for_total_settlement))]
fun settle_swap_total_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>, is_asset_input: bool,
    asset_payment: Balance<Asset>, quote_payment: Balance<Quote>,
    lp_fee_amount: u64, input_spent: u64, output_amount: u64,
    sqrt_price_after_x96: u256, ctx: &TxContext,
): Completion<Asset, Quote, Swap> {
    let (payment, other, reserve_in, reserve_out, vault) = if (is_asset_input) {
        (asset_payment.value(), quote_payment.value(), self.asset_reserve.value(),
            self.quote_reserve.value(), self.asset_fees.value())
    } else {
        (quote_payment.value(), asset_payment.value(), self.quote_reserve.value(),
            self.asset_reserve.value(), self.quote_fees.value())
    };
    let max = std::u64::max_value!() as u128;
    prover::prover::requires(lp_fee_amount <= input_spent && input_spent <= payment);
    prover::prover::requires(output_amount <= reserve_out);
    prover::prover::requires((vault as u128) + (lp_fee_amount as u128) <= max);
    prover::prover::requires((other as u128) + (output_amount as u128) <= max);
    prover::prover::requires((reserve_in as u128) + (input_spent as u128)
        <= max + (lp_fee_amount as u128));
    prover::prover::asserts(true);
    settle_swap(self, is_asset_input, asset_payment, quote_payment, lp_fee_amount,
        input_spent, output_amount, sqrt_price_after_x96, ctx)
}
"""

TOTAL_SETTLEMENT_EVENT = """\
// VM event emission is the external boundary of this arithmetic proof.
#[mode(spec), ext(spec(target = swapped))]
public(package) fun swapped_for_total_settlement(
    pool_id: ID, sender: address, is_asset_input: bool, input_spent: u64, output_amount: u64,
    lp_fee_amount: u64, sqrt_price_after_x96: u256,
) {
    prover::prover::asserts(true);
    swapped(pool_id, sender, is_asset_input, input_spent, output_amount, lp_fee_amount, sqrt_price_after_x96)
}

"""

TICK_FRAMES = """\
#[mode(spec), ext(spec_only, no_abort)]
fun tick_frame(self: &Curve, key: u32): (bool, u128, u128, u256, Growth) {
    let present = self.ticks.contains(key);
    if (present) {
        let tick = table::borrow_or_unknown(&self.ticks, key);
        (true, tick.starts, tick.ends, tick.sqrt_price_x96, tick.outside)
    } else (false, 0, 0, 0, zero())
}

#[mode(spec), ext(spec(target = tick_math::sqrt_price_x96, ignore_abort))]
fun tick_price_for_frame(index: u32): u256 {
    tick_math::sqrt_price_x96(index)
}

#[mode(spec), ext(spec(prove, target = change_tick, ignore_abort, include = tick_price_for_frame))]
fun change_tick_frame_spec(self: &mut Curve, index: u32, start: bool, delta: u128, add: bool) {
    let other = prover::prover::fresh<u32>();
    prover::prover::requires(other != index);
    let (present, starts, ends, price, outside) = tick_frame(self, other);
    change_tick(self, index, start, delta, add);
    let (after_present, after_starts, after_ends, after_price, after_outside) = tick_frame(self, other);
    prover::prover::ensures(present == after_present && starts == after_starts && ends == after_ends);
    prover::prover::ensures(price == after_price && outside == after_outside);
}

#[mode(spec), ext(spec(prove, target = cross))]
fun cross_total_frame_spec(self: &mut Curve, index: u32, up: bool) {
    let (present, starts, ends, price, _) = tick_frame(self, index);
    let leaving = if (up) ends else starts;
    let entering = if (up) starts else ends;
    let other = prover::prover::fresh<u32>();
    let (other_present, other_starts, other_ends, other_price, other_outside) = tick_frame(self, other);
    prover::prover::requires(present && (up || index > 0) && leaving <= self.liquidity);
    prover::prover::requires((self.liquidity as u256) + (entering as u256)
        <= (std::u128::max_value!() as u256) + (leaving as u256));
    prover::prover::asserts(true);
    cross(self, index, up);
    let (after_present, after_starts, after_ends, after_price, _) = tick_frame(self, index);
    prover::prover::ensures(after_present && starts == after_starts && ends == after_ends && price == after_price);
    let (present, starts, ends, price, outside) = tick_frame(self, other);
    prover::prover::ensures(other == index
        || (present == other_present && starts == other_starts && ends == other_ends
            && price == other_price && outside == other_outside));
}
"""
