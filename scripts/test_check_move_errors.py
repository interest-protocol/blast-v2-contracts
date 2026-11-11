"""Mutations that must break the error usage and exact-abort coverage gate."""
from pathlib import Path
import tempfile
import unittest

from check_move_errors import audit, imports, mask_rust, native_oracle


VALUE = '''module example::value;
// === Public Functions ===
public fun require(value: bool) { assert!(value, EInvalid); }
// === Errors ===
#[error(code = 0)]
const EInvalid: vector<u8> = b"Invalid value.";
'''

TEST = '''#[test_only]
module example::value_tests;
// === Tests ===
#[test, expected_failure(abort_code = value::EInvalid, location = value)]
fun invalid() { value::require(false); }
// === Imports ===
use example::{value::{Self}};
'''

REGISTRY = '''module example::errors;
// === Errors ===
#[test_only]
const EInvalid: u64 = 0;
macro public(package) fun invalid(): u64 { 0 }
'''

PIN = '''#[test_only]
module example::errors_tests;
// === Tests ===
#[test]
fun codes() { assert_eq!(example::errors::invalid!(), 0); }
'''


class MoveErrorTests(unittest.TestCase):
    def audit_sources(self, value=VALUE, test=TEST, **extra):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'sui').mkdir()
            for name, source in {'value': value, 'tests': test, **extra}.items():
                if source:
                    (root / 'sui' / f'{name}.move').write_text(source)
            return audit(root)

    def test_named_and_numeric_exact_aborts(self):
        self.assertEqual(self.audit_sources(), ([], 1, 0))
        self.assertEqual(self.audit_sources(test=TEST.replace('value::EInvalid', '0')), ([], 1, 0))

    def test_nested_renamed_imports(self):
        self.assertEqual(imports('use example::{value::{Self as v, Thing}, other};'), {
            'v': 'example::value', 'Thing': 'example::value::Thing', 'other': 'example::other',
        })
        test = TEST.replace('value::', 'v::').replace('location = value', 'location = v')
        test = test.replace('use example::{v::{Self}}', 'use example::{value::{Self as v}}')
        self.assertEqual(self.audit_sources(test=test), ([], 1, 0))

    def test_unused_comment_and_string_are_not_usage(self):
        value = VALUE.replace('assert!(value, EInvalid);', '// EInvalid\nlet _ = b"EInvalid";')
        self.assertIn('example::value::EInvalid: unused in production', self.audit_sources(value=value)[0])

    def test_test_only_function_is_not_production_usage(self):
        value = VALUE.replace('// === Public Functions ===', '// === Test-Only Functions ===\n#[test_only]')
        self.assertIn('example::value::EInvalid: unused in production', self.audit_sources(value=value)[0])

    def test_missing_wrong_location_and_wrong_code_fail(self):
        for test in ('', TEST.replace('location = value', 'location = example::other'),
                     TEST.replace('value::EInvalid', '1')):
            with self.subTest(test=test):
                self.assertIn('example::value::EInvalid: missing exact-abort test at a production raising module',
                              self.audit_sources(test=test)[0])

    def test_expected_failure_requires_code_and_location(self):
        for test in (TEST.replace('abort_code = value::EInvalid, ', ''),
                     TEST.replace(', location = value', '')):
            with self.subTest(test=test), self.assertRaisesRegex(ValueError, 'exact code and location'):
                self.audit_sources(test=test)

    def test_error_gap_fails(self):
        with self.assertRaisesRegex(ValueError, 'sequential'):
            self.audit_sources(value=VALUE.replace('code = 0', 'code = 1'))

    def test_registry_requires_literal_pin_and_real_consumer(self):
        value = VALUE.replace('assert!(value, EInvalid)', 'assert!(value, example::errors::invalid!())')
        value = value.replace('// === Errors ===\n#[error(code = 0)]\nconst EInvalid: vector<u8> = b"Invalid value.";\n', '')
        test = TEST.replace('value::EInvalid', 'example::errors::EInvalid')
        self.assertEqual(self.audit_sources(value, test, errors=REGISTRY, pins=PIN), ([], 1, 0))
        for pins in ('', PIN.replace('!(), 0', '!(), 1'), PIN + '\n// invalid!(), 0\n'):
            failures = self.audit_sources(value, test, errors=REGISTRY, pins=pins)[0]
            if pins == PIN + '\n// invalid!(), 0\n':
                self.assertEqual(failures, [])
            else:
                self.assertIn('example::errors::EInvalid: needs matching numeric registry pins', failures)
        repeated = PIN.replace('assert_eq!(example::errors::invalid!(), 0);',
                               'assert_eq!(example::errors::invalid!(), 0); assert_eq!(example::errors::invalid!(), 0);')
        self.assertEqual(self.audit_sources(value, test, errors=REGISTRY, pins=repeated), ([], 1, 0))

    def test_ordered_vector_pins_need_the_index_assertion(self):
        value = VALUE.replace('assert!(value, EInvalid)', 'assert!(value, example::errors::invalid!())')
        value = value.replace('// === Errors ===\n#[error(code = 0)]\nconst EInvalid: vector<u8> = b"Invalid value.";\n', '')
        test = TEST.replace('value::EInvalid', 'example::errors::EInvalid')
        pin = PIN.replace('assert_eq!(example::errors::invalid!(), 0);', '''
    let codes = vector[example::errors::invalid!()];
    assert_eq!(codes.length(), 1);
    codes.length().do!(|i| assert_eq!(codes[i], i));''')
        self.assertEqual(self.audit_sources(value, test, errors=REGISTRY, pins=pin), ([], 1, 0))
        self.assertTrue(self.audit_sources(value, test, errors=REGISTRY,
                                          pins=pin.replace('assert_eq!(codes[i], i)', 'assert_eq!(codes[i], 1)'))[0])

    def test_native_oracle_requires_actual_function_abort_and_rollback(self):
        source = '''const INVALID_COIN_ORDER: u64 = 0;
fn migration_failures_commit_nothing() {
    let expected = Expected::Abort { package: self.migrators, module: "cetus", code: INVALID_COIN_ORDER };
    self.h.assert_rolled_back(pt, expected);
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'sui/launch/launchpad/ptb_tests/tests/venue_fork.rs'
            path.parent.mkdir(parents=True)
            error = {'name': 'EInvalidCoinOrder', 'code': 0}
            for text, valid in ((source, True), (source.replace('code: INVALID_COIN_ORDER', 'code: 99'), False),
                                (source.replace('u64 = 0', 'u64 = 1'), False),
                                (source.replace('self.h.assert_rolled_back', '// self.h.assert_rolled_back'), False),
                                ('/*' + source + '*/', False)):
                path.write_text(text)
                self.assertEqual(native_oracle(root, 'blast_migrators::errors', error), valid)

    def test_rust_mask_preserves_function_after_char_literals_and_continued_strings(self):
        source = '''let quote = '"'; let lifetime: &'static str = "test";
let message = "continued\\
    message";
fn example() { let text = r#"{ }"#; }
'''
        masked = mask_rust(source)
        self.assertEqual(len(masked), len(source))
        self.assertIn('fn example() {', masked)
        self.assertNotIn('continued', masked)
        self.assertNotIn('\n    message', masked)

    def test_test_only_attribute_formatting_and_leading_comments(self):
        val = '''// Note: do not use #[test_only] on this module
module example::value;
// === Public Functions ===
public fun require(value: bool) { assert!(value, EInvalid); }
// === Errors ===
#[error(code = 0)]
const EInvalid: vector<u8> = b"Invalid value.";
'''
        test = '''#[test_only, allow(lint(abort_without_constant))]
module example::value_tests;
// === Tests ===
#[test, expected_failure(abort_code = value::EInvalid, location = value)]
fun invalid() { value::require(false); }
// === Imports ===
use example::{value::{Self}};
'''
        self.assertEqual(self.audit_sources(value=val, test=test), ([], 1, 0))


if __name__ == '__main__':
    unittest.main()
