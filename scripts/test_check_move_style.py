"""Mutation tests for the repository's declaration and error gate."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from check_move_style import check


REGISTRY = """module example::errors;

// === Errors ===

#[test_only]
const EFirst: u64 = 0;
#[test_only]
const ESecond: u64 = 1;

macro public(package) fun first(): u64 { 0 }
macro public(package) fun second(): u64 { 1 }
"""


class MoveStyleTests(unittest.TestCase):
    def check_source(self, source, filename="errors.move"):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / filename
            path.write_text(source)
            check(path)

    def test_published_utility_layout_does_not_relax_greenfield_layout(self):
        source = """module example::vesting;
// === Constants ===
const LIMIT: u64 = 1;
// === Public Functions ===
public fun limit(): u64 { LIMIT }
// === Events ===
// === Errors ===
// === Imports ===
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch("check_move_style.ROOT", root):
                for package in ("vesting", "launchpad"):
                    path = root / "sui/utilities" / package / "sources" / "vesting.move"
                    path.parent.mkdir(parents=True)
                    path.write_text(source)
                    if package == "vesting":
                        check(path)
                    else:
                        with self.assertRaisesRegex(ValueError, "sections must occur once"):
                            check(path)

    def test_event_payload_and_nested_snapshot_pass(self):
        source = """module example::events;
// === Public Types ===
public struct Snapshot has copy, drop { amount: u64 }
public struct Changed has copy, drop { snapshot: Snapshot }
// === Package Functions ===
public(package) fun changed(amount: u64) {
    sui::event::emit(Changed { snapshot: Snapshot { amount } });
}
"""
        self.check_source(source, "events.move")

    def test_storable_domain_values_in_event_modules_fail(self):
        for filename in ("events.move", "blast_events.move", "blast_admin_events.move"):
            for declaration in (
                "public enum Action has copy, drop, store {\n    Change(u64),\n}",
                "public struct Policy has store { amount: u64 }",
                "public struct State has key { id: UID }",
            ):
                with self.subTest(filename=filename, declaration=declaration):
                    source = f"module example::events;\n// === Public Types ===\n{declaration}\n"
                    with self.assertRaisesRegex(ValueError, "stored domain values"):
                        self.check_source(source, filename)

    def test_unemitted_domain_value_in_event_module_fails(self):
        source = """module example::events;
// === Public Types ===
public enum Action has copy, drop {
    Change(u64),
}
// === Package Functions ===
public(package) fun action(value: u64): Action { Action::Change(value) }
"""
        with self.assertRaisesRegex(ValueError, "only emitted payloads"):
            self.check_source(source, "events.move")

    def test_domain_value_in_owning_module_passes(self):
        source = """module example::package_admin;
// === Public Types ===
public enum UpgradeAction has copy, drop, store {
    Upgrade(vector<u8>),
}
"""
        self.check_source(source, "package_admin.move")

    def test_errors_at_bottom_with_top_constants_pass(self):
        source = """module example::value;
// === Constants ===
const LIMIT: u64 = 10;
// === Public Functions ===
public fun validate(value: u64) { assert!(value <= LIMIT, EInvalid); }
// === Errors ===
#[error(code = 0)]
const EInvalid: vector<u8> = b"Invalid value.";
// === Imports ===
use std::string::String;
"""
        self.check_source(source, "value.move")

    def test_errors_at_bottom_without_imports_pass(self):
        source = """module example::value;
// === Public Functions ===
public fun validate(value: u64) { assert!(value != 0, EInvalid); }
// === Errors ===
#[error(code = 0)]
const EInvalid: vector<u8> = b"Invalid value.";
"""
        self.check_source(source, "value.move")

    def test_errors_before_functions_or_tests_fail(self):
        for section, declaration in (
            ("Public Functions", "public fun validate() {}"),
            ("Tests", "#[test] fun validate() {}"),
        ):
            prefix = "#[test_only]\n" if section == "Tests" else ""
            source = prefix + f"""module example::value;
// === Errors ===
#[error(code = 0)]
const EInvalid: vector<u8> = b"Invalid value.";
// === {section} ===
{declaration}
"""
            with self.subTest(section=section):
                with self.assertRaisesRegex(ValueError, "sections must occur once"):
                    self.check_source(source, "value.move")

    def test_grouped_registry_passes(self):
        self.check_source(REGISTRY)

    def test_consistent_but_gapped_registry_fails(self):
        with self.assertRaisesRegex(ValueError, "sequential"):
            self.check_source(REGISTRY.replace("= 1;", "= 2;").replace("{ 1 }", "{ 2 }"))

    def test_macro_constant_name_mismatch_fails(self):
        with self.assertRaisesRegex(ValueError, "match names"):
            self.check_source(REGISTRY.replace("fun second", "fun another"))

    def test_interleaved_registry_fails(self):
        constant = "#[test_only]\nconst ESecond: u64 = 1;\n"
        source = REGISTRY.replace(constant, "") + constant
        with self.assertRaisesRegex(ValueError, "group all constants"):
            self.check_source(source)

    def test_reservation_tombstone_fails(self):
        with self.assertRaisesRegex(ValueError, "obsolete"):
            self.check_source(REGISTRY + "\n// Code 2 retired: removed check.\n")

    def test_local_error_gap_fails(self):
        source = '''module example::value;
// === Errors ===
#[error(code = 1)]
const EInvalid: vector<u8> = b"Invalid value.";
'''
        with self.assertRaisesRegex(ValueError, "sequential"):
            self.check_source(source, "value.move")

    def test_fixture_error_gap_fails(self):
        source = '''#[test_only]
module example::fixture;
// === Errors ===
const EInvalid: u64 = 1;
'''
        with self.assertRaisesRegex(ValueError, "sequential"):
            self.check_source(source, "fixture.move")

    def test_imports_before_functions_fail(self):
        source = '''module example::value;
// === Imports ===
use std::string::String;
// === Public Functions ===
public fun length(value: &String): u64 { value.length() }
'''
        with self.assertRaisesRegex(ValueError, "sections must occur once"):
            self.check_source(source, "value.move")

    def test_comments_and_strings_do_not_create_declarations(self):
        source = '''module example::value;
// === Constants ===
// fun fake() { }
const TEXT: vector<u8> = b"fun fake() { }; //";
// === Public Functions ===
public fun text(): vector<u8> { TEXT }
'''
        self.check_source(source, "value.move")

    def test_hex_strings_are_masked_like_byte_strings(self):
        # Move's hex literal x"..." must not leak its prefix into the masked
        # source; a bare `x` that survives masking is indistinguishable from an
        # identifier and could feed a later pattern.
        from check_move_style import mask
        self.assertEqual(
            mask('let digest = b"deadbeef";'),
            mask('let digest = x"deadbeef";'),
        )

    def test_uppercase_constants_starting_with_e_are_not_errors(self):
        source = '''#[test_only]
module example::fixture;
// === Constants ===
const EXPECTED_VALUE: u64 = 42;
const EXPIRY: u64 = 100;
'''
        self.check_source(source, "fixture.move")

    def test_module_qualified_types_fail(self):
        for position, line in (
            ("field", "public struct Holder has drop { recipient: payout::Recipient }"),
            ("parameter", "public fun take(_recipient: &mut payout::Recipient) {}"),
            ("return", "public fun make(): payout::Recipient { abort }"),
            ("type argument", "public fun name(): String { schedule_witness<std::string::String>() }"),
            ("local annotation", "public fun read() { let _value: option::Option<u64> = option::none(); }"),
            ("fully qualified", "public fun version(_version: &blast_admin::package_version::PackageVersion) {}"),
            ("qualified variant", "public fun owner(): Destination { payout::Destination::Owner }"),
        ):
            with self.subTest(position=position):
                source = f"module example::value;\n// === Public Functions ===\n{line}\n"
                with self.assertRaisesRegex(ValueError, "import types instead of qualifying them"):
                    self.check_source(source, "value.move")

    def test_imports_comments_attributes_variants_and_calls_pass(self):
        source = '''#[test_only]
module example::value_tests;
// === Tests ===
/// Pays a `payout::Recipient` through `blast_core::payout::Recipient`.
#[test, expected_failure(abort_code = example::errors::EInvalid, location = example::value)]
fun pays() {
    // A `payout::Recipient` in a line comment.
    let label = b"payout::Recipient";
    let _ = Destination::Owner;
    payout::pay_or_vest(Recipient::Owner, label);
    abort example::errors::invalid!()
}
// === Imports ===
use blast_core::payout::{Destination, Recipient};
use fun blast_core::payout::pay_or_vest as Recipient.pay;
'''
        self.check_source(source, "value_tests.move")

    def test_out_of_scope_packages_skip_qualified_type_check(self):
        source = """module example::value;
// === Public Functions ===
public fun make(): payout::Recipient { abort }
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            with patch("check_move_style.ROOT", root):
                for package in ("sui/defi/blast_sui", "sui/defi/boosts/core", "sui/launch/launchpad"):
                    path = root / package / "sources" / "value.move"
                    path.parent.mkdir(parents=True)
                    path.write_text(source)
                    if package == "sui/launch/launchpad":
                        with self.assertRaisesRegex(ValueError, "import types"):
                            check(path)
                    else:
                        check(path)


if __name__ == "__main__":
    unittest.main()
