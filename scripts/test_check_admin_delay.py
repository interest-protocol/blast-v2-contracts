"""check_admin_delay.py must not silently pass when its assertions are compiled out."""
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts' / 'check_admin_delay.py'


class AssertOptimizationTests(unittest.TestCase):
    def test_refuses_to_run_optimized(self):
        # Under -O, Python compiles out every assert; this checker enforces its
        # invariants with assert, so an optimized run would print "OK" while
        # checking nothing. The guard must exit non-zero before any work.
        result = subprocess.run(
            [sys.executable, '-O', str(SCRIPT)], capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('without -O', result.stderr)

    def test_guard_is_absent_in_optimized_bytecode_only(self):
        # The guard must run under a normal interpreter (it is the only thing that
        # distinguishes an optimized run); a normal run reaches the real checks.
        result = subprocess.run(
            [sys.executable, str(SCRIPT)], capture_output=True, text=True,
        )
        self.assertIn('administration boundaries: OK', result.stdout)
        self.assertEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
