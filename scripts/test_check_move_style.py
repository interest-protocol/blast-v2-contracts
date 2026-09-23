"""Mutation tests for the repository's declaration and error gate."""
from pathlib import Path
import tempfile
import unittest

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

    def test_uppercase_constants_starting_with_e_are_not_errors(self):
        source = '''#[test_only]
module example::fixture;
// === Constants ===
const EXPECTED_VALUE: u64 = 42;
const EXPIRY: u64 = 100;
'''
        self.check_source(source, "fixture.move")


if __name__ == "__main__":
    unittest.main()
