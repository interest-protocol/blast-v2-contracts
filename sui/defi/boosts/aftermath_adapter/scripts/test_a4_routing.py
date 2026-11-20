#!/usr/bin/env python3
"""Check the closed-market boundary that abort-only venue fixtures cannot execute."""
from pathlib import Path
import re
import unittest

from move_source import replace_code


OPERATIONS = Path(__file__).resolve().parents[1] / "sources" / "trading" / "operations.move"


def check_route(source):
    body = source.split("fun unwind_settlement<", 1)[1].split("\n}\n", 1)[0]
    body = re.sub(r"/\*.*?\*/|//[^\n]*", "", body, flags=re.S)
    body = re.sub(r"\s+", "", body)
    ordered = [
        "letbefore=binding.capture_checkpoint(",
        "let(enabled,base_price,collateral_price)=clearing_house.settlement_valuation_prices();",
        "assert_settlement_valuation(enabled,base_price,base_price.is_neg(),collateral_price,collateral_price.is_neg(),);",
        "clearing_house.close_position_at_settlement_prices(account,&vector[]);",
        "letafter=binding.capture_checkpoint(",
        "vault.complete_settlement_unwind(before,after,collateral_price);",
    ]
    positions = [body.index(call) for call in ordered]
    assert positions == sorted(positions)
    # Paused markets cannot use ordinary synchronization. Booking the earlier
    # interval here would also round two offsetting settlements separately.
    for forbidden in ("apply_post_capture(", "settle_position_funding(", "update_funding(",
                      "synchronize_", "capture_valuation("):
        assert forbidden not in body


class SettlementRoutingTests(unittest.TestCase):
    def test_close_uses_live_captures_and_enabled_settlement_price(self):
        check_route(OPERATIONS.read_text())

    def test_wrong_price_missing_booking_and_paused_sync_are_detected(self):
        source = OPERATIONS.read_text()
        completion = "vault.complete_settlement_unwind(before, after, collateral_price);"
        mutations = [
            replace_code(source, completion, completion.replace("collateral_price", "base_price")),
            replace_code(source, completion, completion.replace("collateral_price", "1_000_000_000_000_000_000")),
            replace_code(source, completion, "// " + completion),
            replace_code(source, completion, completion.replace("before, after", "before, before")),
            replace_code(source, "let after = binding.capture_checkpoint(", "let before = binding.capture_checkpoint("),
            replace_code(source, completion, "vault.apply_post_capture(before, preexisting);\n" + completion),
            replace_code(source, completion, "clearing_house.update_funding(clock);\n" + completion),
        ]
        for mutated in mutations:
            with self.subTest():
                self.assertNotEqual(source, mutated)
                with self.assertRaises((AssertionError, ValueError)):
                    check_route(mutated)


if __name__ == "__main__":
    unittest.main()
