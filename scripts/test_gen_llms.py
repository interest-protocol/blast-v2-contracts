"""Verify reference generation, summary identities and publication status."""
import io
import json
from functools import partialmethod
from pathlib import Path, PureWindowsPath
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import gen_llms


class SummaryIdentityTests(unittest.TestCase):
    def test_summary_uses_mainnet_regardless_of_cli_default(self):
        with (
            patch.object(gen_llms, 'PACKAGES', [('sui/example', 'Example')]),
            patch.object(gen_llms, 'package_name', return_value='example'),
            patch.object(gen_llms.subprocess, 'run') as run,
        ):
            run.return_value.returncode = 0
            gen_llms.build_summaries(Path('summaries'))

        command = run.call_args.args[0]
        self.assertEqual(command[command.index('--build-env') + 1], 'mainnet')

    def test_genesis_alias_does_not_rename_package_or_type_references(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / 'sui/example'
            (package / 'sources/config').mkdir(parents=True)
            (package / 'Move.toml').write_text('[package]\nname = "example"\n')
            (package / 'sources/config/policy.move').write_text('module example::policy;\n')
            summaries = root / 'summaries'
            summary = summaries / 'example'
            (summary / 'treasury').mkdir(parents=True)
            (summary / 'address_mapping.json').write_text(json.dumps({
                'example': '0x0', 'treasury': '0x0', 'sui': '0x2',
            }))
            (summary / 'treasury/policy.json').write_text(json.dumps({
                'id': {'address': 'treasury', 'name': 'policy'},
                'references': [{'address': 'treasury'}, {'address': 'sui'}],
                'doc': 'treasury',
            }))
            with patch.object(gen_llms, 'ROOT', root):
                result = gen_llms.load_package('sui/example', 'Example', summaries)
            module = result.modules['policy']
            self.assertEqual(module['id']['address'], 'example')
            self.assertEqual(module['references'], [{'address': 'example'}, {'address': 'sui'}])
            self.assertEqual(module['doc'], 'treasury')
            self.assertEqual(set(result.sources), {'policy'})


class ReferencePortabilityTests(unittest.TestCase):
    def test_module_source_link_uses_forward_slashes_on_windows(self):
        root = PureWindowsPath('C:/checkout')
        source = root / 'sui/launch/presale/sources/example.move'
        package = gen_llms.Package(path='sui/launch/presale', title='Example', name='example')
        package.sources['example'] = source
        package.modules['example'] = {'structs': {}, 'functions': {}}

        with (
            patch.object(gen_llms, 'ROOT', root),
            patch.object(PureWindowsPath, 'read_text', create=True, return_value='const MAX: u64 = 1;'),
        ):
            lines = gen_llms.module_reference(package, 'example', {'example'})

        self.assertIn(f'Source: {gen_llms.REPO_URL}/sui/launch/presale/sources/example.move', lines)

    def test_check_and_write_work_with_windows_text_defaults(self):
        with tempfile.TemporaryDirectory() as tmp, io.TextIOWrapper(io.BytesIO(), encoding='cp1252') as stdout:
            root = Path(tmp)
            output = root / 'llms-full.txt'
            argv = ['gen_llms.py', '--summaries', tmp]
            with (
                patch.object(gen_llms, 'ROOT', root),
                patch.object(gen_llms, 'PRODUCT_DIR', root / 'llms'),
                patch.object(gen_llms, 'generate', return_value={output: 'Status — current\n'}),
                patch.object(Path, 'read_text', partialmethod(Path.read_text, encoding='cp1252')),
                patch.object(Path, 'write_text', partialmethod(Path.write_text, encoding='cp1252', newline='\r\n')),
                patch.object(gen_llms.sys, 'stdout', stdout),
                patch.object(gen_llms.sys, 'argv', argv),
            ):
                gen_llms.main()
                self.assertEqual(output.read_bytes(), 'Status — current\n'.encode('utf-8'))

                argv.append('--check')
                output.write_bytes('Status — current\r\n'.encode('utf-8'))
                gen_llms.main()

                output.write_bytes('Status → stale\r\n'.encode('utf-8'))
                with self.assertRaisesRegex(SystemExit, r'^stale: llms-full\.txt:'):
                    gen_llms.main()
                stdout.flush()
                self.assertIn(b'Status \\u2192 stale', stdout.buffer.getvalue())


class FrozenPackageTests(unittest.TestCase):
    def test_boosts_reference_is_generated_from_local_sources(self):
        self.assertNotIn('boosts.md', gen_llms.frozen_guides())
        for path, _ in gen_llms.PACKAGES:
            if path.startswith('sui/defi/boosts/'):
                self.assertNotIn(path, gen_llms.FROZEN)

    def test_summaries_skip_frozen_packages(self):
        with (
            patch.object(gen_llms, 'FROZEN', {'sui/defi/boosts/core': 'example'}),
            patch.object(gen_llms, 'PACKAGES', [('sui/defi/boosts/core', 'Frozen'), ('sui/example', 'Example')]),
            patch.object(gen_llms, 'package_name', return_value='example'),
            patch.object(gen_llms.subprocess, 'run') as run,
        ):
            run.return_value.returncode = 0
            gen_llms.build_summaries(Path('summaries'))

        self.assertEqual(run.call_count, 1)
        command = run.call_args.args[0]
        self.assertTrue(Path(command[command.index('-p') + 1]).as_posix().endswith('sui/example'))

    def test_frozen_guide_and_reference_sections_are_copied_verbatim(self):
        frozen = gen_llms.Package(path='sui/defi/boosts/core', title='Boosts core', name='boosts')
        guide_heading = gen_llms.guide_heading('boosts.md')
        committed_text = '\n'.join([
            '# header', '',
            guide_heading, '', 'committed guide, stale on purpose', '',
            gen_llms.reference_heading(frozen), '', 'committed reference', '',
        ])
        committed = gen_llms.committed_sections(committed_text)
        with (
            patch.object(gen_llms, 'deployment', return_value={'live': False}),
            patch.object(gen_llms, 'FROZEN', {frozen.path: 'example'}),
            patch.object(gen_llms, 'GUIDES', [('boosts.md', [frozen.path])]),
            patch.object(gen_llms, 'package_reference', side_effect=AssertionError('frozen package rebuilt')),
        ):
            text = gen_llms.assemble('# header\n', ['boosts.md'], [frozen], {}, {'boosts'}, committed)

        self.assertIn('\n'.join(committed[guide_heading]), text)
        self.assertIn('committed reference', text)
        self.assertTrue(text.endswith('committed reference\n'))

    def test_committed_sections_split_at_each_top_level_heading(self):
        sections = gen_llms.committed_sections('# top\n## A\na\n### sub\n## B\nb\n')
        self.assertEqual(sections['## A'], ['## A', 'a', '### sub'])
        self.assertEqual(sections['## B'], ['## B', 'b', ''])


class PublicationPathTests(unittest.TestCase):
    def test_dependency_does_not_override_its_own_publication(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / 'sui/example'
            package.mkdir(parents=True)
            (package / 'Published.toml').write_text(
                '[published.mainnet]\npublished-at = "0x42"\noriginal-id = "0x42"\n'
            )
            records = root / 'deployments/sui/mainnet'
            records.mkdir(parents=True)
            (records / '01-example.json').write_text(json.dumps({
                'recordKind': 'deployment',
                'status': 'success',
                'repository': {'commit': 'example-revision'},
                'packages': {'example': {'packageId': '0x42'}},
            }))
            (records / '02-vendor.json').write_text(json.dumps({
                'recordKind': 'deployment',
                'status': 'success',
                'repository': {'commit': 'vendor-revision'},
                'packageId': '0x43',
                'dependencies': {'example': '0x42'},
            }))
            self.addCleanup(gen_llms.deployment.cache_clear)
            with (
                patch.object(gen_llms, 'ROOT', root),
                patch.object(gen_llms, 'matches_publication', return_value=True) as matches,
            ):
                self.assertTrue(gen_llms.deployment('sui/example')['matches'])
                matches.assert_called_once_with('sui/example', 'example-revision')

    def test_moved_package_matches_its_publication_only_with_the_same_sources_and_edges(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            old = root / 'sui/core'
            (old / 'sources').mkdir(parents=True)
            source = 'sources/core.move'
            (old / source).write_text('module example::core;\n')
            (old / 'Move.toml').write_text('[dependencies]\nAdmin = { local = "../admin" }\n')

            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, text=True)

            git('init', '-q')
            git('add', '.')
            git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'publication')
            commit = git('rev-parse', 'HEAD').strip()
            current = root / 'sui/launch/core'
            current.parent.mkdir()
            old.rename(current)
            manifest = current / 'Move.toml'
            manifest.write_text('[dependencies]\nAdmin = { local = "../../governance/admin" }\n')

            with patch.object(gen_llms, 'ROOT', root):
                self.assertTrue(gen_llms.matches_publication('sui/launch/core', commit))
                manifest.write_text(manifest.read_text().replace('/admin', '/other'))
                self.assertFalse(gen_llms.matches_publication('sui/launch/core', commit))
                manifest.write_text(manifest.read_text().replace('/other', '/admin'))
                (current / source).write_text('module example::changed;\n')
                self.assertFalse(gen_llms.matches_publication('sui/launch/core', commit))


if __name__ == '__main__':
    unittest.main()
