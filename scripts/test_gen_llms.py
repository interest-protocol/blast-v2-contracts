"""Summary identities must survive the zero-valued genesis address placeholders."""
import json
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


class FrozenPackageTests(unittest.TestCase):
    """Boosts (#205) is kept verbatim until it adopts the folded admin."""

    def test_frozen_packages_are_the_out_of_scope_products(self):
        self.assertEqual(
            set(gen_llms.FROZEN),
            {'sui/defi/boosts/core', 'sui/defi/boosts/products', 'sui/defi/boosts/aftermath_adapter'},
        )
        self.assertEqual(gen_llms.frozen_guides(), {'boosts.md'})

    def test_summaries_skip_frozen_packages(self):
        with (
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
            root = Path(tmp)
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


class PlatformConsistencyTests(unittest.TestCase):
    """The same inputs must generate the same references on every platform (#254)."""

    def test_repo_path_uses_forward_slashes_for_a_windows_path(self):
        root = PureWindowsPath('C:/repo')
        source = root / 'sui/launch/presale/sources/blast_presale.move'
        with patch.object(gen_llms, 'ROOT', root):
            self.assertEqual(
                gen_llms.repo_path(source),
                'sui/launch/presale/sources/blast_presale.move',
            )

    def test_guide_heading_reads_a_utf8_guide(self):
        # Written as raw UTF-8 bytes: a locale-encoded read (e.g. CP1252 on
        # Windows) would hand back mojibake for the em dash instead.
        with tempfile.TemporaryDirectory() as tmp:
            guides = Path(tmp)
            (guides / 'presale.md').write_bytes('# Presale — buying in\n'.encode('utf-8'))
            with patch.object(gen_llms, 'GUIDES_DIR', guides):
                self.assertEqual(gen_llms.guide_heading('presale.md'), '# Presale — buying in')


if __name__ == '__main__':
    unittest.main()
