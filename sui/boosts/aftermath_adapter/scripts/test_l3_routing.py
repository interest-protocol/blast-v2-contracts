#!/usr/bin/env python3
"""Pin authenticated fee and funding inputs where external ABI stubs prevent execution."""
from pathlib import Path
import re
import unittest


SOURCES = Path(__file__).resolve().parents[1] / "sources"


def compact(source):
    return re.sub(r"\s+", "", re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S))


def check_routes(operations, snapshot):
    readiness = compact(operations.split("public fun needs_rebalance<", 1)[1].split("\n}\n", 1)[0])
    classification = compact("let funding = vault.venue().checkpoint().classify_preexisting(&capture.checkpoint());")
    consumption = compact("capture.into_rebalance_readiness(vault.state(), funding,")
    assert classification in readiness and consumption in readiness
    assert readiness.index(classification) < readiness.index(consumption)
    assert compact("""vault.state().prepare_mint(before, deposit, vault.total_share_supply(),
        minimum_shares, clearing_house.live_venue_fee_bps(), clock.timestamp_ms())""") in compact(operations)
    assert compact(""".into_rebalance_readiness(vault.state(), funding,
        clearing_house.live_venue_fee_bps(), clock.timestamp_ms(),)""") in compact(operations)
    assert compact("state.needs_rebalance(observation, settlement, margin_safe, venue_fee_bps, now_at_ms)") in compact(snapshot)


class FeeRoutingTests(unittest.TestCase):
    def test_live_calls_use_the_market_fee(self):
        check_routes((SOURCES / "operations.move").read_text(), (SOURCES / "snapshot.move").read_text())

    def test_comparing_the_stored_checkpoint_to_itself_is_rejected(self):
        operations = (SOURCES / "operations.move").read_text()
        mutated = operations.replace("classify_preexisting(&capture.checkpoint())",
                                     "classify_preexisting(vault.venue().checkpoint())")
        self.assertNotEqual(operations, mutated)
        with self.assertRaises(AssertionError):
            check_routes(mutated, (SOURCES / "snapshot.move").read_text())

    def test_replacing_any_authenticated_fee_or_commenting_out_a_call_fails(self):
        operations = (SOURCES / "operations.move").read_text()
        snapshot = (SOURCES / "snapshot.move").read_text()
        mutations = [
            (operations.replace("minimum_shares, clearing_house.live_venue_fee_bps()", "minimum_shares, 0"), snapshot),
            (operations.replace("vault.state(), funding, clearing_house.live_venue_fee_bps()",
                                "vault.state(), funding, 0"), snapshot),
            (operations, snapshot.replace("observation, settlement, margin_safe, venue_fee_bps", "observation, settlement, margin_safe, 0")),
            (operations.replace("let plan = vault.state().prepare_mint(before", "// let plan = vault.state().prepare_mint(before"), snapshot),
        ]
        for ops, snap in mutations:
            with self.subTest():
                with self.assertRaises(AssertionError):
                    check_routes(ops, snap)


if __name__ == "__main__":
    unittest.main()
