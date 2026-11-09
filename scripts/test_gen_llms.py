"""Summary identities, frozen packages, publication status, and platform-independent references."""
import ast
import io
import json
from pathlib import Path, PureWindowsPath
import subprocess
import sys
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
    """blast_sui (#191) and Boosts (#205) are kept verbatim until they adopt the folded admin."""

    def test_frozen_packages_are_the_out_of_scope_products(self):
        self.assertEqual(
            set(gen_llms.FROZEN),
            {'sui/defi/blast_sui', 'sui/defi/boosts/core', 'sui/defi/boosts/products', 'sui/defi/boosts/aftermath_adapter'},
        )
        self.assertEqual(gen_llms.frozen_guides(), {'blast-sui.md', 'boosts.md'})

    def test_summaries_skip_frozen_packages(self):
        with (
            patch.object(gen_llms, 'PACKAGES', [('sui/defi/blast_sui', 'Frozen'), ('sui/example', 'Example')]),
            patch.object(gen_llms, 'package_name', return_value='example'),
            patch.object(gen_llms.subprocess, 'run') as run,
        ):
            run.return_value.returncode = 0
            gen_llms.build_summaries(Path('summaries'))

        self.assertEqual(run.call_count, 1)
        command = run.call_args.args[0]
        self.assertTrue(Path(command[command.index('-p') + 1]).as_posix().endswith('sui/example'))

    def test_frozen_guide_and_reference_sections_are_copied_verbatim(self):
        frozen = gen_llms.Package(path='sui/defi/blast_sui', title='blastSUI and funSUI', name='blast_sui')
        guide_heading = gen_llms.guide_heading('blast-sui.md')
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
            text = gen_llms.assemble('# header\n', ['blast-sui.md'], [frozen], {}, {'blast_sui'}, committed)

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

    @staticmethod
    def publish_then_move(root: Path) -> str:
        """Commits `sui/core`, then moves it to `sui/launch/core` with its edge rewritten."""
        old = root / 'sui/core'
        (old / 'sources').mkdir(parents=True)
        (old / 'sources/core.move').write_text('module example::core;\n')
        (old / 'Move.toml').write_text('[dependencies]\nAdmin = { local = "../admin" }\n')

        def git(*args):
            return subprocess.check_output(['git', *args], cwd=root, text=True)

        git('init', '-q')
        git('add', '.')
        git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'publication')
        current = root / 'sui/launch/core'
        current.parent.mkdir()
        old.rename(current)
        (current / 'Move.toml').write_text('[dependencies]\nAdmin = { local = "../../governance/admin" }\n')
        return git('rev-parse', 'HEAD').strip()

    def test_moved_package_matches_its_publication_only_with_the_same_sources_and_edges(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            commit = self.publish_then_move(root)
            current = root / 'sui/launch/core'
            source = 'sources/core.move'
            manifest = current / 'Move.toml'

            with patch.object(gen_llms, 'ROOT', root):
                self.assertTrue(gen_llms.matches_publication('sui/launch/core', commit))
                manifest.write_text(manifest.read_text().replace('/admin', '/other'))
                self.assertFalse(gen_llms.matches_publication('sui/launch/core', commit))
                manifest.write_text(manifest.read_text().replace('/other', '/admin'))
                (current / source).write_text('module example::changed;\n')
                self.assertFalse(gen_llms.matches_publication('sui/launch/core', commit))

    def test_moved_package_matches_its_publication_through_an_unresolved_root(self):
        # A symlinked checkout, like a Windows 8.3 short-name temp root, resolves to another prefix.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'checkout'
            root.mkdir()
            alias = Path(tmp) / 'alias'
            try:
                alias.symlink_to(root, target_is_directory=True)
            except OSError:
                self.skipTest('symlinks are unavailable')
            commit = self.publish_then_move(root)
            with patch.object(gen_llms, 'ROOT', alias):
                self.assertTrue(gen_llms.matches_publication('sui/launch/core', commit))


class PlatformConsistencyTests(unittest.TestCase):
    """#254: the same sources render the same reference bytes on Windows and Linux."""

    def test_source_url_uses_forward_slashes_for_a_windows_checkout(self):
        class WindowsSource(PureWindowsPath):
            def read_text(self, encoding=None, errors=None):
                return 'module example::policy;\nconst LIMIT: u64 = 1;\n'

        root = PureWindowsPath('C:/repo')
        source = WindowsSource('C:/repo/sui/launch/presale/sources/policy.move')
        self.assertIn('\\', str(source.relative_to(root)))
        pkg = gen_llms.Package(
            path='sui/launch/presale', title='Presale', name='example',
            modules={'policy': {'structs': {}, 'functions': {}}}, sources={'policy': source},
        )
        with patch.object(gen_llms, 'ROOT', root):
            lines = gen_llms.module_reference(pkg, 'policy', set())
            self.assertIn(f'Source: {gen_llms.REPO_URL}/sui/launch/presale/sources/policy.move', lines)
            # The helper `--check` uses to name stale references.
            self.assertEqual(gen_llms.repo_path(root / 'llms/presale.txt'), 'llms/presale.txt')

    def test_generate_and_check_round_trip_on_a_cp1252_crlf_host(self):
        # A Windows host without UTF-8 mode: CP1252 is the default text encoding, writes translate
        # LF to CRLF, and redirected stdout encodes CP1252 strictly.
        read, write = Path.read_text, Path.write_text

        def host_read(self, encoding=None, errors=None, **kwargs):
            return read(self, encoding=encoding or 'cp1252', errors=errors, **kwargs)

        def host_write(self, data, encoding=None, errors=None, newline=None):
            return write(self, data, encoding=encoding or 'cp1252', errors=errors,
                         newline='\r\n' if newline is None else newline)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / 'sui/example'
            (package / 'sources/nested').mkdir(parents=True)
            (package / 'Move.toml').write_bytes(b'[package]\nname = "example"\n')
            (package / 'sources/nested/policy.move').write_bytes(
                'module example::policy;\n/// Price \u2212 fee.\nconst LIMIT: u64 = 1;\n'.encode('utf-8')
            )
            guides = root / 'docs/llms'
            guides.mkdir(parents=True)
            (guides / 'basics.md').write_bytes('# Basics\n\nAmounts \u2264 the cap.\n'.encode('utf-8'))
            summary = root / 'summaries/example'
            (summary / 'example').mkdir(parents=True)
            (summary / 'address_mapping.json').write_bytes(b'{"example": "0x0"}')
            (summary / 'example/policy.json').write_bytes(json.dumps({
                'id': {'address': 'example', 'name': 'policy'}, 'structs': {}, 'functions': {},
            }).encode('utf-8'))
            output = root / 'llms-full.txt'
            stdout = io.TextIOWrapper(io.BytesIO(), encoding='cp1252', errors='strict')

            def run(*flags):
                with patch.object(sys, 'argv', ['gen_llms.py', '--summaries', str(root / 'summaries'), *flags]):
                    gen_llms.main()

            gen_llms.deployment.cache_clear()
            self.addCleanup(gen_llms.deployment.cache_clear)
            with (
                patch.multiple(
                    gen_llms, ROOT=root, OUTPUT=output, PRODUCT_DIR=root / 'llms', GUIDES_DIR=guides,
                    PACKAGES=[('sui/example', 'Example')], FROZEN={}, GUIDES=[('basics.md', [])], PRODUCTS=[],
                ),
                patch.object(Path, 'read_text', host_read),
                patch.object(Path, 'write_text', host_write),
                patch.object(sys, 'stdout', stdout),
            ):
                run()
                data = output.read_bytes()
                run('--check')
                output.write_bytes(data.replace('Price \u2212 fee'.encode('utf-8'), 'Price \u2212 tax'.encode('utf-8')))
                with self.assertRaises(SystemExit) as stale:
                    run('--check')

        self.assertNotIn(b'\r\n', data)
        text = data.decode('utf-8')
        self.assertIn('| `example` | Example | not yet published | \u2014 | \u2014 |', text)
        self.assertIn('Amounts \u2264 the cap.', text)
        self.assertIn('- `LIMIT: u64 = 1`: Price \u2212 fee.', text)
        self.assertIn(f'Source: {gen_llms.REPO_URL}/sui/example/sources/nested/policy.move', text)
        self.assertEqual(str(stale.exception), 'stale: llms-full.txt: run python3 scripts/gen_llms.py')
        stdout.flush()
        printed = stdout.buffer.getvalue().decode('cp1252')
        self.assertIn('llms-full.txt and llms/ are current.', printed)
        self.assertIn('+- `LIMIT: u64 = 1`: Price \\u2212 fee.', printed)

    def test_text_io_names_its_encoding(self):
        # A call that leaves the encoding to the host decodes the same bytes differently on Windows.
        tree = ast.parse(Path(gen_llms.__file__).read_text(encoding='utf-8'))
        def name(call):
            return call.func.attr if isinstance(call.func, ast.Attribute) else getattr(call.func, 'id', None)

        calls = [
            node for node in ast.walk(tree)
            if isinstance(node, ast.Call) and name(node) in {'read_text', 'write_text', 'open', 'run', 'check_output'}
        ]
        self.assertTrue(calls)
        for call in calls:
            keywords = {keyword.arg for keyword in call.keywords}
            if name(call) in {'run', 'check_output'} and not keywords & {'text', 'encoding', 'universal_newlines'}:
                continue  # bytes output
            if name(call) in {'read_text', 'write_text'} and isinstance(call.func, ast.Name):
                continue  # the module's own UTF-8 helpers
            with self.subTest(call=ast.unparse(call)):
                self.assertIn('encoding', keywords)
                if name(call) == 'write_text':
                    self.assertIn('newline', keywords)


if __name__ == '__main__':
    unittest.main()
