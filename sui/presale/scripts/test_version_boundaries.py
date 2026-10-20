#!/usr/bin/env python3
"""Prove the surface gate detects removal of every public mutation guard."""
import ast
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class VersionBoundaryTests(unittest.TestCase):
    def test_each_guard_is_required(self):
        package = Path(__file__).resolve().parent.parent
        script = package / 'scripts/check_version_boundaries.py'
        tree = ast.parse(script.read_text())
        guarded = next(ast.literal_eval(node.value) for node in tree.body
                       if isinstance(node, ast.Assign)
                       and any(isinstance(target, ast.Name) and target.id == 'GUARDED'
                               for target in node.targets))
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            shutil.copytree(package / 'sources', root / 'sources')
            (root / 'scripts').mkdir()
            check = root / 'scripts' / script.name
            shutil.copyfile(script, check)
            baseline = subprocess.run(['python3', str(check)], capture_output=True)
            self.assertEqual(baseline.returncode, 0, baseline.stderr)
            for module, functions in guarded.items():
                path = root / 'sources' / (module + '.move')
                original = path.read_text()
                for name in functions:
                    with self.subTest(module=module, function=name):
                        start = original.index('public fun ' + name + '(') if name == 'commit_upgrade_and_advance' else original.index('public fun ' + name)
                        guard = 'assert_next' if name == 'commit_upgrade_and_advance' else 'assert_current'
                        statement = f'package_version.{guard}();'
                        offset = original.index(statement, start)
                        path.write_text(original[:offset] + original[offset + len(statement):])
                        result = subprocess.run(['python3', str(check)], capture_output=True)
                        self.assertNotEqual(result.returncode, 0, f'{module}::{name}')
                        path.write_text(original)


if __name__ == '__main__':
    unittest.main()
