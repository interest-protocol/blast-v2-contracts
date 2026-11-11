"""Move specifications staged for the tick bitmap proof."""

# The Move control-flow proof is parametric in the deterministic scan. The
# separate bitvector proof instantiates it with the pinned eight-step scan.
SCAN_BPL = """\
function $NearestBitmapScan(bits: int, up: bool): int;
axiom (forall bits: int, up: bool :: {$NearestBitmapScan(bits, up)}
    0 <= $NearestBitmapScan(bits, up) && $NearestBitmapScan(bits, up) <= 255);
procedure {:inline 1} $0_curve_scan_bit_model(bits: int, up: bool) returns (result: int) {
    result := $NearestBitmapScan(bits, up);
}
"""

LOOKUP_SPECS = """\
#[mode(spec), ext(spec(target = tick_math::floor_index, ignore_abort))]
fun floor_cursor_bound(price_x96: u256, lower: u32, upper: u32): u32 {
    let result = tick_math::floor_index(price_x96, lower, upper);
    prover::prover::ensures(lower > upper || (lower <= result && result <= upper));
    result
}

#[mode(spec), ext(spec(prove, target = new, ignore_abort, include = floor_cursor_bound))]
fun new_bitmap_spec(price_x96: u256, ctx: &mut TxContext): Curve {
    // Check membership at an arbitrary key.
    let key = prover::prover::fresh<u32>();
    let result = new(price_x96, ctx);
    prover::prover::ensures(result.index <= 2 * constants::max_tick!() && result.group_index == 0);
    prover::prover::ensures(!result.ticks.contains(key) && !result.words.contains(key) && !result.groups.contains(key));
    result
}

#[mode(spec), ext(spec_only, no_abort)]
native fun scan_bit_model(bits: u256, up: bool): u32;

#[mode(spec), ext(spec(target = bit_index, ignore_abort))]
fun scan_bit_for_lookup(bits: u256, up: bool): u32 {
    let expected = scan_bit_model(bits, up);
    let result = bit_index(bits, up);
    prover::prover::ensures(result == expected && result <= 255);
    result
}

#[mode(spec), ext(spec_only, no_abort)]
fun lookup_candidate(word: u32, bits: u256, up: bool): (bool, u64) {
    (true, ((word << 8) as u64) + (scan_bit_model(bits, up) as u64))
}

// On a successful lookup, the selected child exists and its value equals
// the zero-default bitmap read. Descend only the selected branch.
#[mode(spec), ext(spec_only, no_abort)]
fun lookup_trace(self: &Curve, up: bool): (bool, u64) {
    if (self.index < 0 || self.index > 2 * constants::max_tick!()) return (false, 0);
    let start = self.index + if (up) 1 else 0;
    let word = start >> 8;
    let group = word >> 8;
    if (word < 0 || group < 0 || group > 255) return (false, 0);
    let bit = (start % 256) as u8;
    let slot = (word % 256) as u8;
    if ((1u256 << bit) <= 0 || (1u256 << slot) <= 0 || (1u256 << (group as u8)) <= 0) {
        return (false, 0)
    };

    let bits = at_or_beyond(bitmap(&self.words, word), bit, up);
    if (bits != 0) return lookup_candidate(word, bits, up);

    let words = strictly_beyond(bitmap(&self.groups, group), slot, up);
    let (selected_group, children) = if (words != 0) (group, words) else {
        let groups = strictly_beyond(self.group_index, group as u8, up);
        if (groups == 0) return (false, 0);
        let selected_group = scan_bit_model(groups, up);
        (selected_group, bitmap(&self.groups, selected_group))
    };
    let selected_word = ((selected_group << 8) as u64) + (scan_bit_model(children, up) as u64);
    if (selected_word < 0 || selected_word > (std::u32::max_value!() as u64)) return (false, 0);
    let selected_word = selected_word as u32;
    lookup_candidate(selected_word, bitmap(&self.words, selected_word), up)
}

#[mode(spec), ext(spec(prove, target = next_tick, ignore_abort,
    include = scan_bit_for_lookup, extra_bpl = b"nearest_scan.bpl"))]
fun next_tick_spec(self: &Curve, up: bool): Option<u32> {
    let (present, index) = lookup_trace(self, up);
    prover::prover::requires(self.index >= 0 && self.index <= 2 * constants::max_tick!());
    let word = (self.index + if (up) 1 else 0) >> 8;
    let group = word >> 8;
    prover::prover::requires(word >= 0 && group >= 0 && group <= 255);
    prover::prover::requires((1u256 << (((self.index + if (up) 1 else 0) % 256) as u8)) > 0);
    prover::prover::requires((1u256 << ((word % 256) as u8)) > 0 && (1u256 << (group as u8)) > 0);
    let result = next_tick(self, up);
    prover::prover::ensures(result.is_some() == present);
    let payload = *result.borrow_with_default(&0);
    if (present) prover::prover::ensures((payload as u64) == index);
    result
}
"""

LOOKUP_TOTAL_SPECS = """\
#[mode(spec), ext(spec(prove, target = tick_price))]
public(package) fun stored_tick_price_total_spec(self: &Curve, index: u32): u256 {
    prover::prover::requires(self.ticks.contains(index));
    prover::prover::asserts(true);
    tick_price(self, index)
}

"""

LOOKUP_RETURN_BPL = SCAN_BPL + """\
function $LookupMask(bits: int, bit: int, up: bool, strict: bool): int;
procedure {:inline 1} $0_curve_lookup_mask(bits: int, bit: int, up: bool, strict: bool)
    returns (result: int) {
    result := $LookupMask(bits, bit, up, strict);
}
"""

LOOKUP_RETURN_SPECS = """\
#[mode(spec), ext(spec_only, no_abort)]
native fun scan_bit_model(bits: u256, up: bool): u32;

#[mode(spec), ext(spec_only, no_abort)]
native fun lookup_mask(bits: u256, bit: u8, up: bool, strict: bool): u256;

// Instantiate these deterministic operations with the Z3 bitvector model.
#[mode(spec), ext(spec(target = bit_index))]
fun total_lookup_scan(bits: u256, up: bool): u32 {
    let model = scan_bit_model(bits, up);
    prover::prover::asserts(true);
    let result = bit_index(bits, up);
    prover::prover::ensures(result == model && result <= 255);
    result
}

#[mode(spec), ext(spec(target = at_or_beyond))]
fun total_lookup_inclusive(bits: u256, bit: u8, up: bool): u256 {
    let model = lookup_mask(bits, bit, up, false);
    prover::prover::asserts(true);
    let result = at_or_beyond(bits, bit, up);
    prover::prover::ensures(result == model);
    result
}

#[mode(spec), ext(spec(target = strictly_beyond))]
fun total_lookup_exclusive(bits: u256, bit: u8, up: bool): u256 {
    let model = lookup_mask(bits, bit, up, true);
    prover::prover::asserts(true);
    let result = strictly_beyond(bits, bit, up);
    prover::prover::ensures(result == model);
    result
}

#[mode(spec), ext(spec_only, no_abort)]
fun lookup_return_candidate(word: u32, bits: u256, up: bool): (bool, Option<u32>) {
    let result = ((word << 8) as u64) + (scan_bit_model(bits, up) as u64);
    if (result < 0 || result > (std::u32::max_value!() as u64)) return (false, option::none());
    (true, option::some(result as u32))
}

#[mode(spec), ext(spec_only, no_abort)]
fun lookup_return_trace(self: &Curve, up: bool): (bool, Option<u32>) {
    if (self.index < 0 || self.index > 2 * constants::max_tick!()) return (false, option::none());
    let start = self.index + if (up) 1 else 0;
    let word = start >> 8;
    let group = word >> 8;
    if (word < 0 || word > 65535 || group < 0 || group > 255) return (false, option::none());
    let bits = lookup_mask(bitmap(&self.words, word), (start % 256) as u8, up, false);
    if (bits != 0) return lookup_return_candidate(word, bits, up);
    let words = lookup_mask(bitmap(&self.groups, group), (word % 256) as u8, up, true);
    let (selected, children) = if (words != 0) (group, words) else {
        let groups = lookup_mask(self.group_index, group as u8, up, true);
        if (groups == 0) return (true, option::none());
        let selected = scan_bit_model(groups, up);
        if (!self.groups.contains(selected)) return (false, option::none());
        let children = bitmap(&self.groups, selected);
        if (children == 0) return (false, option::none());
        (selected, children)
    };
    let key = ((selected << 8) as u64) + (scan_bit_model(children, up) as u64);
    if (key < 0 || key > (std::u32::max_value!() as u64)) return (false, option::none());
    let key = key as u32;
    if (!self.words.contains(key)) return (false, option::none());
    let ticks = bitmap(&self.words, key);
    if (ticks == 0) return (false, option::none());
    lookup_return_candidate(key, ticks, up)
}

#[mode(spec), ext(spec(prove, target = next_tick, include(
    a = total_lookup_scan, b = total_lookup_inclusive, c = total_lookup_exclusive,
), extra_bpl = b"lookup_return.bpl"))]
public(package) fun next_tick_return_spec(self: &Curve, up: bool): Option<u32> {
    let (live, expected) = lookup_return_trace(self, up);
    prover::prover::requires(live);
    prover::prover::asserts(true);
    let result = next_tick(self, up);
    prover::prover::ensures(result == expected);
    result
}
"""

TICK_TARGET_READINESS = """\
#[mode(spec), ext(spec_only, no_abort)]
public(package) fun swap_target_keys_live(self: &Curve, up: bool): bool {
    let (live, expected) = lookup_return_trace(self, up);
    live && (!expected.is_some() || self.ticks.contains(*expected.borrow()))
}

"""

SWAP_TARGET_SPEC = """\
#[mode(spec), ext(spec(prove, target = swap_target, include(
    a = curve::next_tick_return_spec, b = curve::stored_tick_price_total_spec,
), extra_bpl = b"curve/lookup_return.bpl"))]
fun swap_target_return_spec<Asset, Quote>(
    self: &Pool<Asset, Quote>, sqrt_price_limit_x96: u256, up: bool,
): (Option<u32>, u256, u256) {
    prover::prover::requires(self.curve.swap_target_keys_live(up));
    prover::prover::asserts(true);
    let (tick, price, target) = swap_target(self, sqrt_price_limit_x96, up);
    prover::prover::ensures(tick.is_some() || price == sqrt_price_limit_x96);
    prover::prover::ensures(target == (if (up) price.min(sqrt_price_limit_x96) else price.max(sqrt_price_limit_x96)));
    (tick, price, target)
}

"""


def isolate_swap_target(source):
    """Extract the read-only loop prefix in the staged package."""
    prefix = (
        "        let tick = self.curve.next_tick(up);\n"
        "        let tick_price = if (tick.is_some()) self.curve.tick_price(*tick.borrow()) else sqrt_price_limit_x96;\n"
        "        let target = if (up) tick_price.min(sqrt_price_limit_x96) else tick_price.max(sqrt_price_limit_x96);\n"
    )
    marker = "/// Integrate one fee per initialized liquidity interval"
    if source.count(prefix) != 1 or source.count(marker) != 1:
        raise SystemExit("Could not locate the swap tick and target prefix.")
    body = "".join(line[4:] + "\n" for line in prefix.splitlines())
    helper = (
        "fun swap_target<Asset, Quote>(\n"
        "    self: &Pool<Asset, Quote>, sqrt_price_limit_x96: u256, up: bool,\n"
        "): (Option<u32>, u256, u256) {\n"
        + body + "    (tick, tick_price, target)\n}\n\n"
    )
    return source.replace(prefix, "        let (tick, tick_price, target) = self.swap_target(sqrt_price_limit_x96, up);\n", 1).replace(
        marker, helper + marker, 1,
    )
