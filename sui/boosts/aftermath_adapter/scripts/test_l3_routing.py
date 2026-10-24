#!/usr/bin/env python3
"""Pin authenticated L3 fee inputs where external ABI stubs prevent execution."""
from pathlib import Path
import re
import unittest


SOURCES = Path(__file__).resolve().parents[1] / "sources"


def compact(source):
    return re.sub(r"\s+", "", re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S))


def check_routes(operations, snapshot):
    assert compact("""vault.state().prepare_mint(before, deposit, vault.total_share_supply(),
        minimum_shares, clearing_house.live_venue_fee_bps(), clock.timestamp_ms())""") in compact(operations)
    assert compact(""".into_rebalance_readiness(vault.state(),
        clearing_house.live_venue_fee_bps(), clock.timestamp_ms())""") in compact(operations)
    assert compact("state.needs_rebalance(observation, margin_safe, venue_fee_bps, now_at_ms)") in compact(snapshot)


class FeeRoutingTests(unittest.TestCase):
    def test_live_calls_use_the_market_fee(self):
        check_routes((SOURCES / "operations.move").read_text(), (SOURCES / "snapshot.move").read_text())

    def test_replacing_any_authenticated_fee_or_commenting_out_a_call_fails(self):
        operations = (SOURCES / "operations.move").read_text()
        snapshot = (SOURCES / "snapshot.move").read_text()
        mutations = [
            (operations.replace("minimum_shares, clearing_house.live_venue_fee_bps()", "minimum_shares, 0"), snapshot),
            (operations.replace(".into_rebalance_readiness(vault.state(), clearing_house.live_venue_fee_bps()",
                                ".into_rebalance_readiness(vault.state(), 0"), snapshot),
            (operations, snapshot.replace("observation, margin_safe, venue_fee_bps", "observation, margin_safe, 0")),
            (operations.replace("let plan = vault.state().prepare_mint(before", "// let plan = vault.state().prepare_mint(before"), snapshot),
        ]
        for ops, snap in mutations:
            with self.subTest():
                with self.assertRaises(AssertionError):
                    check_routes(ops, snap)


if __name__ == "__main__":
    unittest.main()
