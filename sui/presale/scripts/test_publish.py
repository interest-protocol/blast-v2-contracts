#!/usr/bin/env python3
"""Exercise publication status handling without signing or broadcasting transactions."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class PublicationTests(unittest.TestCase):
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
