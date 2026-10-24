#!/usr/bin/env python3
"""M7 source-routing regressions, not an executable Aftermath simulation.

Move tests execute the storage guard and captured-state accounting. These checks
pin the production reads that ABI stubs cannot execute locally. Mutations prove
the gate rejects representative regressions; live rotation remains a release gate.
"""

from pathlib import Path
import re
import unittest


SOURCES = Path(__file__).resolve().parents[1] / "sources"


def production(source):
    source = source.split("// === Test-Only Functions ===")[0]
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)


def compact(source):
    return re.sub(r"\s+", "", source)


def body(source, name, kind="fun"):
    declaration = re.search(rf"\b{kind}\s+{name}\b", source)
    if declaration is None:
        raise AssertionError(f"Missing {kind} {name}")
    start = source.index("{", declaration.end())
    depth = 1
    end = start + 1
    while depth and end < len(source):
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    assert depth == 0, f"Unclosed {name}"
    return source[start + 1:end - 1]


def contains(source, *fragments):
    for fragment in fragments:
        assert compact(fragment) in compact(source), f"Missing routing: {fragment}"


def ordered(source, *fragments):
    offset = 0
    normalized = compact(source)
    for fragment in fragments:
        match = normalized.find(compact(fragment), offset)
        assert match >= 0, f"Missing or reordered routing: {fragment}"
        offset = match + len(compact(fragment))


def check_binding(sources):
    assert compact(body(sources["venue_account"], "Binding", "struct")) == compact("""
        account_object_id: ID, account_number: u64,
        registry_id: ID, clearing_house_id: ID,
    """), "Binding must not cache oracle storage, source or feed-origin ids"
    checkpoint = body(sources["checkpoint"], "Checkpoint", "struct")
    assert not re.search(r"oracle|feed|source", checkpoint), "Checkpoint must not pin oracle identities"
    assert compact(body(sources["venue_account"], "VenueAccount", "struct")) == compact("""
        binding: Binding, checkpoint: Checkpoint, admin_cap: AuthorityCap<ACCOUNT, ADMIN>,
    """), "VenueAccount must not cache oracle identities outside Binding"
    # Recreated feeds can retain their storage/source while changing origin.
    for module in sources.values():
        assert not re.search(r"\.from\s*\(", module), "Feed origin must not be pinned"
        assert not re.search(r"object::id\s*\(\s*(?:base|collateral)_oracle\s*\)", module), \
            "Oracle object identity must not be pinned outside the current market storage check"


def check_storage_authentication(sources):
    contains(body(sources["venue_account"], "assert_market_oracles"), """
        let params = clearing_house.market_params();
        assert_market_oracle_ids!(
            base_oracle.storage_id(), params.base_storage_id(),
            collateral_oracle.storage_id(), params.collateral_storage_id(),
        );
    """)
    contains(body(sources["snapshot"], "assert_bound_graph"), """
        binding.assert_object_graph(
            object::id(account), account.account_id(), object::id(registry), object::id(clearing_house),
        );
        clearing_house.assert_market_oracles(base_oracle, collateral_oracle);
    """)
    contains(body(sources["venue_account"], "update_funding_when_due"), """
        self.assert_funding_update_inputs(object::id(clearing_house), base_oracle.storage_id(), params.base_storage_id());
    """)
    for operation in ("execute_order", "withdraw"):
        ordered(body(sources["venue_account"], operation),
                ".assert_market_account(", ".assert_market_oracles(base_oracle, collateral_oracle)")


def check_current_feeds(sources):
    for capture in ("capture", "capture_order_capacity"):
        route = body(sources["snapshot"], capture)
        authentication = ".capture_checkpoint(" if capture == "capture" else ".assert_bound_graph("
        ordered(route, authentication, "let params = clearing_house.market_params();",
                "let base_feed = &base_oracle[params.base_source_id()];",
                "let collateral_feed = &collateral_oracle[params.collateral_source_id()];")
        contains(route, "params.base_oracle_price(base_oracle, clock)",
                 "params.collateral_oracle_price(collateral_oracle, clock)",
                 "base_feed.oracle_leg(", "collateral_feed.oracle_leg(")
    contains(body(sources["snapshot"], "oracle_leg"),
             "feed.price_and_timestamp_ms()", "oracle_leg_decoded(feed_price, price_published_at_ms, venue_price)")
    contains(body(sources["snapshot"], "oracle_leg_decoded"), """
        assert!((feed_price as u256) == venue_price,
            blast_boosts_aftermath::errors::oracle_observation_mismatch!(),);
    """)


def check_mint_routing(sources):
    ordered(body(sources["operations"], "mint"),
            ".synchronize_or_fail(", ".prepare_mint(", ".fill_orders(", ".capture(", ".complete_mint<")
    contains(body(sources["operations"], "synchronize_or_fail"),
             "vault.synchronize(account, registry, clearing_house, base_oracle, collateral_oracle, clock)")
    synchronization = body(sources["operations"], "synchronize")
    assert synchronization.count("binding.capture(") == 2
    ordered(synchronization, ".update_funding_when_due(", "let pre_capture = binding.capture(",
            ".settle_position_funding(", "let post_capture = binding.capture(")


def check_terminal_routing(sources):
    # Exact body: adding even an unused feed read would reintroduce the freeze.
    assert compact(body(sources["snapshot"], "capture_checkpoint")) == compact("""
        binding.assert_bound_graph(account, registry, clearing_house, base_oracle, collateral_oracle);
        account.read_checkpoint(clearing_house)
    """), "Terminal checkpoint capture must authenticate without reading any feed"
    raw = body(sources["checkpoint"], "read_checkpoint")
    assert not re.search(r"oracle|price|feed", raw), "Raw checkpoint must remain price-independent"
    for operation in ("unwind_settlement", "finalize_shutdown"):
        route = body(sources["operations"], operation)
        assert route.count("binding.capture_checkpoint(") == 2
        assert not re.search(r"\.(?:capture|synchronize\w*|update_funding_when_due)\s*\(", route)
        assert not re.search(r"(?:base|collateral)_oracle\s*(?:\[|\.)", route)
    settlement = body(sources["operations"], "unwind_settlement")
    ordered(settlement, "let before = binding.capture_checkpoint(",
            ".settlement_valuation_prices()", "assert_settlement_valuation(",
            ".close_position_at_settlement_prices(", "let after = binding.capture_checkpoint(")
    ordered(body(sources["operations"], "finalize_shutdown"),
            "let before = binding.capture_checkpoint(", ".recoverable_terminal_cash()",
            ".withdraw(", "let after = binding.capture_checkpoint(", ".complete_finalization(")
    # Withdrawal may call venue deallocation: this gate does not establish its
    # external price requirements or promise all shutdowns work with missing feeds.


CHECKS = (check_binding, check_storage_authentication, check_current_feeds,
          check_mint_routing, check_terminal_routing)


class OracleRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sources = {path.stem: production(path.read_text())
                       for path in SOURCES.rglob("*.move")}

    def test_current_production_routing(self):
        for check in CHECKS:
            with self.subTest(check=check.__name__):
                check(self.sources)

    def test_realistic_m7_regressions_are_rejected(self):
        mutations = [
            ("venue_account", "Binding", "struct", "account_number: u64,", "account_number: u64, base_feed_id: ID,"),
            ("venue_account", "VenueAccount", "struct", "binding: Binding,", "binding: Binding, base_oracle_id: ID,"),
            ("snapshot", "assert_bound_graph", "fun", "binding.assert_object_graph(", "assert!(object::id(base_oracle) == @0xA.to_id(), 7); binding.assert_object_graph("),
            ("vault", "set_max_order_notional", "fun", "protocol.assert_current();", "protocol.assert_current(); let _id = object::id(collateral_oracle);"),
            ("vault", "set_max_order_notional", "fun", "protocol.assert_current();", "protocol.assert_current(); let _origin = collateral_oracle[0].from();"),
            ("venue_account", "assert_market_oracles", "fun", "params.base_storage_id()", "10"),
            ("venue_account", "assert_market_oracles", "fun", "params.collateral_storage_id()", "20"),
            ("venue_account", "assert_market_oracles", "fun", "base_oracle.storage_id()", "params.base_storage_id()"),
            ("venue_account", "assert_market_oracles", "fun", "collateral_oracle.storage_id()", "params.collateral_storage_id()"),
            ("snapshot", "assert_bound_graph", "fun", "object::id(clearing_house)", "@0xC.to_id()"),
            ("snapshot", "assert_bound_graph", "fun", "clearing_house.assert_market_oracles(base_oracle, collateral_oracle);", ""),
            ("venue_account", "update_funding_when_due", "fun", "params.base_storage_id()", "10"),
            ("snapshot", "capture", "fun", "params.base_source_id()", "0"),
            ("snapshot", "capture", "fun", "params.collateral_source_id()", "0"),
            ("snapshot", "capture_order_capacity", "fun", "params.base_source_id()", "0"),
            ("snapshot", "capture_order_capacity", "fun", "params.collateral_source_id()", "0"),
            ("snapshot", "capture", "fun", "let base_feed =", "let _origin = base_oracle[params.base_source_id()].from(); let base_feed ="),
            ("snapshot", "oracle_leg_decoded", "fun", "(feed_price as u256) == venue_price", "true"),
            ("snapshot", "capture_checkpoint", "fun", "account.read_checkpoint(clearing_house)", "let _feed = &base_oracle[0]; account.read_checkpoint(clearing_house)"),
            ("snapshot", "capture_checkpoint", "fun", "account.read_checkpoint(clearing_house)", "let _feed = &collateral_oracle[0]; account.read_checkpoint(clearing_house)"),
            ("checkpoint", "read_checkpoint", "fun", "let params =", "let _price = clearing_house.mark_price(base_oracle, clock); let params ="),
            ("operations", "mint", "fun", "vault.synchronize_or_fail(", "vault.cached_capture("),
            ("operations", "synchronize", "fun", "let post_capture = binding.capture(", "let post_capture = binding.cached_capture("),
            ("operations", "unwind_settlement", "fun", "binding.capture_checkpoint(", "binding.capture("),
            ("operations", "finalize_shutdown", "fun", "binding.capture_checkpoint(", "binding.capture("),
        ]
        for module, name, kind, old, new in mutations:
            with self.subTest(module=module, function=name, mutation=new):
                sources = self.sources.copy()
                original = body(sources[module], name, kind)
                self.assertIn(old, original)
                sources[module] = sources[module].replace(original, original.replace(old, new), 1)
                with self.assertRaises(AssertionError):
                    for check in CHECKS:
                        check(sources)


if __name__ == "__main__":
    unittest.main()
