#!/usr/bin/env python3
"""Pin the receipt's sole production sink and checked-amount routing."""
from pathlib import Path
import re
import unittest

from move_source import replace_code


ORDERS = Path(__file__).resolve().parents[1] / "sources/trading/orders.move"


def function(source, name):
    return source.split(f"fun {name}", 1)[1].split("\n}\n", 1)[0]


def check_route(source):
    source = source.split("// === Test-Only Functions ===", 1)[0]
    source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
    assert re.search(r"public struct FillReceipt\s*\{", source)
    assert re.search(r"\nfun proven_fill\(\s*self:\s*FillReceipt,", source)
    assert re.search(r"\nfun place_order<", source)
    # Declaration, producer return + construction, consumer argument + unpack.
    assert len(re.findall(r"\bFillReceipt\b", source)) == 5
    assert "FillReceipt { filled, filled_quote }" in function(source, "place_order")
    assert "let FillReceipt { filled, filled_quote } = self;" in function(source, "proven_fill")
    assert source.count(".place_order(") == source.count(".proven_fill(") == 4
    for caller, capture, advance in (
        ("fill_orders", ".capture_checkpoint(", "remaining = remaining - filled"),
        ("rebalance_orders", ".into_rebalance_observation(plan)", ".accept_rebalance_fill(plan, order, after, filled,"),
        ("close_orders", ".capture_checkpoint(", "remaining = remaining - filled"),
        ("fill_exact_order", ".capture_checkpoint(", "(clearing_house, after)"),
    ):
        body = re.sub(r"\s+", "", function(source, caller))
        advance = re.sub(r"\s+", "", advance)
        assert body.index(".place_order(") < body.index(capture) < body.index("receipt.proven_fill(") < body.index(advance)
        if caller == "fill_exact_order":
            assert body.index("receipt.filled==base") < body.index(capture)
            assert body.count("receipt.filled") == 1
        else:
            assert "receipt.filled" not in body
    close = re.sub(r"\s+", "", function(source, "close_orders"))
    assert "let(filled,quote)=receipt.proven_fill(" in close
    assert "filled_quote.checked_add(quote)" in close


class FillReceiptRoutingTests(unittest.TestCase):
    def test_production_receipts_must_pass_the_only_consumer(self):
        check_route(ORDERS.read_text())

    def test_bypasses_and_unchecked_progress_are_detected(self):
        source = ORDERS.read_text()
        mutations = [
            replace_code(source, "struct FillReceipt {", "struct FillReceipt has drop {"),
            replace_code(source, "self: FillReceipt,", "self: &FillReceipt,"),
            replace_code(source, "fun proven_fill(", "public(package) fun proven_fill("),
            replace_code(source, "let (filled, _) = receipt.proven_fill(&terms, &checkpoint, &after_checkpoint);", "let filled = receipt.filled;"),
            replace_code(source, "after, filled, clock.timestamp_ms()", "after, receipt.filled, clock.timestamp_ms()"),
            replace_code(source, "filled_quote.checked_add(quote)", "filled_quote.checked_add(receipt.filled_quote)"),
            replace_code(source, "let (_, _) = receipt.proven_fill(&terms, before, &after);", ""),
            replace_code(source, "// === Test-Only Functions ===", "fun discard(receipt: FillReceipt) { let FillReceipt { .. } = receipt; }\n// === Test-Only Functions ==="),
        ]
        for mutated in mutations:
            with self.subTest():
                self.assertNotEqual(source, mutated)
                with self.assertRaises((AssertionError, ValueError)):
                    check_route(mutated)


if __name__ == "__main__":
    unittest.main()
