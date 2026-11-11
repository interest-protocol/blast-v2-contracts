"""Stage an observation of the production swap loop for Sui Prover."""

CURSOR_ACCESSOR = """\
public(package) fun progress_cursor(self: &Curve): u32 { self.index }

"""

LOOKUP_FOR_PROGRESS = """\
// The reachable-bitmap proof discharges this consequence of nearest lookup.
#[mode(spec), ext(spec(target = next_tick, ignore_abort))]
fun next_tick_for_progress(self: &Curve, up: bool): Option<u32> {
    let result = next_tick(self, up);
    if (result.is_some()) {
        let index = *result.borrow();
        prover::prover::ensures(index >= 0 && index <= 2 * constants::max_tick!());
        prover::prover::ensures(if (up) index > self.index else index <= self.index);
    };
    result
}

"""

PROGRESS_SPEC = """\
#[mode(spec), ext(spec_only(loop_inv(target = swap_amounts)), no_abort)]
#[allow(unused_function)]
fun swap_progress_invariant<Asset, Quote>(
    self: &Pool<Asset, Quote>, steps: u64, progress_ok: bool,
): bool {
    let cursor = self.curve.progress_cursor();
    progress_ok && steps >= 0 && steps <= constants::max_swap_steps!()
        && cursor >= 0 && cursor <= 2 * constants::max_tick!()
}

#[mode(spec), ext(spec(prove, target = swap_amounts, ignore_abort, include(
    a = continuous_fee::swap_step_budget_spec,
    b = blast_fun_dex::curve::next_tick_for_progress,
    c = blast_fun_dex::curve::tick_price_for_budget,
    d = blast_fun_dex::curve::credit_spec,
    e = blast_fun_dex::curve::cross_spec,
    f = blast_fun_dex::curve::move_inside_for_budget,
)))]
fun swap_progress_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    is_asset_input: bool,
    input_value: u64,
    sqrt_price_limit_x96: u256,
    fee_path: ContinuousPath,
    allow_zero_partial: bool,
): (u64, u64, u256, u64, bool, u64) {
    let cursor = self.curve.progress_cursor();
    prover::prover::requires(cursor >= 0 && cursor <= 2 * constants::max_tick!());
    let (spent, output, price, fee, progress_ok, steps) = swap_amounts(
        self, is_asset_input, input_value, sqrt_price_limit_x96, fee_path, allow_zero_partial,
    );
    prover::prover::ensures(progress_ok && steps <= constants::max_swap_steps!());
    (spent, output, price, fee, progress_ok, steps)
}

"""


def instrument_swap_progress(source):
    # Read-only snapshots and extra result fields let the prover check each
    # back edge without introducing an abort or changing any production branch.
    # Each insertion is tied to a unique source anchor.
    edits = (
        ("let (input_spent, output_amount, sqrt_price_after_x96, lp_fee_amount) =\n"
         "        self.swap_amounts(",
         "let (input_spent, output_amount, sqrt_price_after_x96, lp_fee_amount, _, _) =\n"
         "        self.swap_amounts("),
        ("allow_zero_partial: bool,\n): (u64, u64, u256, u64) {\n    let up = !is_asset_input;",
         "allow_zero_partial: bool,\n): (u64, u64, u256, u64, bool, u64) {\n    let up = !is_asset_input;"),
        ("    let mut steps = 0;\n    while (remaining",
         "    let mut steps = 0;\n    let mut progress_ok = true;\n    while (remaining"),
        ("        steps = steps + 1;\n        let tick = self.curve.next_tick(up);",
         """        let steps_before = steps;
        let cursor_before = self.curve.progress_cursor();
        let remaining_before = remaining;
        let output_before = output_x64;
        let fee_before = total_fee;
        steps = steps + 1;
        progress_ok = progress_ok && steps == steps_before + 1 && steps <= constants::max_swap_steps!();
        let tick = self.curve.next_tick(up);"""),
        ("            spot = target;\n        } else {\n            break",
         """            spot = target;
            progress_ok = progress_ok && spot == tick_price
                && remaining == remaining_before && output_x64 == output_before && total_fee == fee_before;
        } else {
            break"""),
        ("            self.curve.cross(tick.destroy_some(), up);",
         """            self.curve.cross(tick.destroy_some(), up);
            let cursor_after = self.curve.progress_cursor();
            progress_ok = progress_ok && (if (up) cursor_after > cursor_before else cursor_after < cursor_before);"""),
        ("    (input_value - remaining, output as u64, spot, total_fee)",
         "    (input_value - remaining, output as u64, spot, total_fee, progress_ok, steps)"),
    )
    for anchor, replacement in edits:
        if source.count(anchor) != 1:
            raise SystemExit(f"Could not locate swap progress proof anchor: {anchor!r}")
        source = source.replace(anchor, replacement, 1)
    return source
