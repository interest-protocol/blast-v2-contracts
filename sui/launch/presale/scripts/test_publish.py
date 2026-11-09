#!/usr/bin/env python3
"""Exercise publication status handling without signing or broadcasting transactions."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class PublicationTests(unittest.TestCase):
    def test_finalization_passes_publication_and_cap(self):
        script = Path(__file__).resolve().parent / 'wrap_package_admin.sh'
        with tempfile.TemporaryDirectory() as temp:
            fake_sui = Path(temp) / 'sui'
            fake_sui.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            fake_sui.chmod(0o755)
            for mode in ['--preview', '--execute']:
                result = subprocess.run(
                    ['bash', str(script), '0x1a', '0x10', '0x20', '0x30', mode],
                    env={**os.environ, 'PATH': temp + os.pathsep + os.environ['PATH']},
                    capture_output=True, text=True, check=True,
                )
                expected = ['client', '--client.env', 'mainnet', 'ptb', '--move-call',
                            '0x1a::package_admin::wrap<0x10::blast_presale_package::BLAST_PRESALE_PACKAGE>',
                            '@0x20', '@0x30', '--json']
                if mode == '--preview':
                    expected.append('--preview')
                self.assertEqual(result.stdout.splitlines(), expected)
            result = subprocess.run(['bash', str(script), '0x1a', '0x10', '0x30', '--execute'],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 2)

    def test_extra_arguments_are_rejected_before_invoking_sui(self):
        scripts = Path(__file__).resolve().parent
        commands = (
            ('publish.sh', []),
            ('wrap_package_admin.sh', ['0x1a', '0x10', '0x20', '0x30']),
        )
        with tempfile.TemporaryDirectory() as temp:
            fake_sui = Path(temp) / 'sui'
            fake_sui.write_text('#!/bin/sh\nprintf "%s\\n" "unexpected sui invocation" >&2\nexit 99\n')
            fake_sui.chmod(0o755)
            for script, args in commands:
                for modes in (['--execute', '--preview'], ['--preview', '--execute']):
                    with self.subTest(script=script, modes=modes):
                        result = subprocess.run(
                            ['bash', str(scripts / script), *args, *modes],
                            env={**os.environ, 'PATH': temp + os.pathsep + os.environ['PATH']},
                            capture_output=True, text=True,
                        )
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn('usage:', result.stderr)
                        self.assertNotIn('unexpected sui invocation', result.stderr)

    def test_cli_and_transaction_status_must_both_succeed(self):
        package = Path(__file__).resolve().parent.parent
        success = '{"effects":{"status":{"status":"success"}}}'
        cases = [
            (success, 0, True),
            ('{"effects":{"status":{"status":"failure","error":"PublishUpgradeMissingDependency"}}}', 0, False),
            ('{}', 0, False),
            ('{"effects":null}', 0, False),
            ('{"effects":{"status":{"status":"unknown"}}}', 0, False),
            ('not JSON', 0, False),
            (success, 23, False),
        ]
        with tempfile.TemporaryDirectory() as temp:
            fake_sui = Path(temp) / 'sui'
            fake_sui.write_text(
                '#!/bin/sh\n'
                'printf "%s\\n" "$@" > "$PUBLISH_ARGS"\n'
                'printf "%s" "$PUBLISH_RESPONSE"\n'
                'exit "$PUBLISH_EXIT"\n'
            )
            fake_sui.chmod(0o755)
            args_file = Path(temp) / 'args'
            for mode in ['--preview', '--execute']:
                for response, cli_exit, accepted in cases:
                    with self.subTest(mode=mode, response=response, cli_exit=cli_exit):
                        result = subprocess.run(
                            ['bash', str(package / 'scripts/publish.sh'), mode],
                            env={**os.environ, 'PATH': temp + os.pathsep + os.environ['PATH'],
                                 'PUBLISH_ARGS': str(args_file), 'PUBLISH_RESPONSE': response,
                                 'PUBLISH_EXIT': str(cli_exit)},
                            capture_output=True, text=True, check=False,
                        )
                        self.assertEqual(result.returncode == 0, accepted, result.stderr)
                        expected_args = ['client', '--client.env', 'mainnet', 'publish', str(package), '--json']
                        if mode == '--preview':
                            expected_args.append('--dry-run')
                        self.assertEqual(args_file.read_text().splitlines(), expected_args)
                        if response.startswith('{'):
                            self.assertEqual(json.loads(result.stdout), json.loads(response))


if __name__ == '__main__':
    unittest.main()
