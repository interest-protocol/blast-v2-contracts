#!/usr/bin/env python3
"""Prove the surface gate detects removal of every public mutation guard."""
import ast
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class VersionBoundaryTests(unittest.TestCase):
    def copy_checker(self, temp):
        package = Path(__file__).resolve().parent.parent
        root = Path(temp) / 'presale'
        shutil.copytree(package / 'sources', root / 'sources')
        (root / 'scripts').mkdir()
        check = root / 'scripts/check_version_boundaries.py'
        shutil.copyfile(package / 'scripts' / check.name, check)
        reader = Path('launchpad/scripts/move_facts.awk')
        (root.parent / reader.parent).mkdir(parents=True)
        shutil.copyfile(package.parent / reader, root.parent / reader)
        return root, check

    def test_unreviewed_mutable_entry_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root, check = self.copy_checker(temp)
            policy = root / 'sources/config/creation_policy.move'
            original = policy.read_text()
            marker = '// === Public Functions ==='
            for modifier in ('entry', 'public entry', 'public(package) entry'):
                with self.subTest(modifier=modifier):
                    function = (f'{modifier} fun reset_quotes(self: &mut CreationPolicy) {{\n'
                                '    self.allowed_quotes = vec_set::empty();\n}')
                    policy.write_text(original.replace(marker, marker + '\n' + function))
                    result = subprocess.run([sys.executable, str(check)], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('Unreviewed mutable entry point: creation_policy::reset_quotes', result.stderr)

    def test_nested_module_cannot_define_package_administration(self):
        with tempfile.TemporaryDirectory() as temp:
            root, check = self.copy_checker(temp)
            rogue = root / 'sources/config/rogue.move'
            rogue.write_text('module blast_presale::rogue;\npublic struct PackageAdmin() has drop;\n')
            result = subprocess.run([sys.executable, str(check)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('public struct PackageAdmin', result.stderr)

    def test_each_guard_is_required(self):
        package = Path(__file__).resolve().parent.parent
        script = package / 'scripts/check_version_boundaries.py'
        tree = ast.parse(script.read_text())
        guarded = next(ast.literal_eval(node.value) for node in tree.body
                       if isinstance(node, ast.Assign)
                       and any(isinstance(target, ast.Name) and target.id == 'GUARDED'
                               for target in node.targets))
        with tempfile.TemporaryDirectory() as temp:
            root, check = self.copy_checker(temp)
            baseline = subprocess.run([sys.executable, str(check)], capture_output=True)
            self.assertEqual(baseline.returncode, 0, baseline.stderr)
            for module, functions in guarded.items():
                paths = list((root / 'sources').rglob(module + '.move'))
                self.assertEqual(len(paths), 1, module)
                path = paths[0]
                original = path.read_text()
                for name in functions:
                    with self.subTest(module=module, function=name):
                        start = original.index('public fun ' + name + '<') if ('public fun ' + name + '<') in original else original.index('public fun ' + name + '(')
                        statement = 'package_version.assert_current(constants::version!());'
                        offset = original.index(statement, start)
                        path.write_text(original[:offset] + original[offset + len(statement):])
                        result = subprocess.run([sys.executable, str(check)], capture_output=True)
                        self.assertNotEqual(result.returncode, 0, f'{module}::{name}')
                        path.write_text(original)


if __name__ == '__main__':
    unittest.main()
