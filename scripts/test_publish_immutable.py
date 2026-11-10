"""Extra arguments must not reach the immutable mainnet publication PTB."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = (
    ROOT / 'sui/governance/admin/scripts/publish_immutable.sh',
    ROOT / 'sui/launch/partners/scripts/publish_immutable.sh',
    ROOT / 'sui/launch/vendors/aftermath_dao_presale/scripts/publish_immutable.sh',
)
REJECTED = (
    [],
    ['--preview', '--execute'],
    ['--execute', '--preview'],
    ['--preview', 'extra'],
)


class PublishImmutableArgumentTests(unittest.TestCase):
    def run_script(self, script, args, env):
        return subprocess.run(
            ['bash', str(script), *args],
            env=env,
            capture_output=True,
            text=True,
        )

    def test_extra_arguments_are_rejected_before_invoking_sui(self):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'sui-invocations'
            fake_sui = Path(temp) / 'sui'
            fake_sui.write_text(
                '#!/bin/sh\n'
                'printf "%s\\n" "$@" >> "$SUI_INVOCATION_LOG"\n'
                'exit 99\n'
            )
            fake_sui.chmod(0o755)
            env = {
                **os.environ,
                'PATH': temp + os.pathsep + os.environ['PATH'],
                'SUI_INVOCATION_LOG': str(log),
            }
            for script in SCRIPTS:
                for args in REJECTED:
                    with self.subTest(script=script.relative_to(ROOT), args=args):
                        log.write_text('')
                        result = self.run_script(script, args, env)
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertEqual(
                            result.stderr,
                            f'usage: {script} <--preview|--execute>\n',
                        )
                        self.assertEqual(result.stdout, '')
                        self.assertEqual(log.read_text(), '')

    def test_one_mode_still_invokes_sui(self):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'sui-invocations'
            fake_sui = Path(temp) / 'sui'
            fake_sui.write_text(
                '#!/bin/sh\n'
                'printf "%s\\n" "$@" >> "$SUI_INVOCATION_LOG"\n'
                'exit 99\n'
            )
            fake_sui.chmod(0o755)
            env = {
                **os.environ,
                'PATH': temp + os.pathsep + os.environ['PATH'],
                'SUI_INVOCATION_LOG': str(log),
            }
            for script in SCRIPTS:
                package_dir = str(script.parent.parent)
                for mode in ('--preview', '--execute'):
                    with self.subTest(script=script.relative_to(ROOT), mode=mode):
                        log.write_text('')
                        result = self.run_script(script, [mode], env)
                        self.assertEqual(result.returncode, 99, result.stderr)
                        invoked = log.read_text().splitlines()
                        self.assertEqual(invoked[:4], ['client', '--client.env', 'mainnet', 'ptb'])
                        self.assertIn('--publish', invoked)
                        self.assertEqual(invoked[invoked.index('--publish') + 1], package_dir)
                        if mode == '--preview':
                            self.assertEqual(invoked[-1], '--preview')
                        else:
                            self.assertNotIn('--preview', invoked)


if __name__ == '__main__':
    unittest.main()
