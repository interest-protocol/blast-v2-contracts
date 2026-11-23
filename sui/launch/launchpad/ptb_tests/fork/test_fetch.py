"""Offline snapshot refresh tests. Run with python -m unittest test_fetch."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import fetch


class SnapshotWriteTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.out = Path(tmp.name) / "snapshot"
        dest = patch.object(fetch, "OUT", self.out)
        dest.start()
        self.addCleanup(dest.stop)
        self.write_package(1)

    def write_package(self, version):
        snapshot = fetch.Snapshot(version)
        snapshot.packages[f"0x{version}"] = {
            "raw": bytes([version]), "version": version, "digest": "test", "role": "test",
        }
        fetch.write(snapshot, "test")

    def assert_snapshot(self, version):
        manifest = json.loads((self.out / "manifest.json").read_bytes())
        self.assertEqual(manifest["checkpoint"], version)
        entry, = manifest["packages"]
        self.assertEqual((self.out / entry["file"]).read_bytes(), bytes([version]))

    def test_manifest_write_failure_preserves_previous_snapshot(self):
        with patch.object(Path, "write_text", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                self.write_package(2)
        self.assert_snapshot(1)
        self.assertEqual(list(self.out.parent.iterdir()), [self.out])

    def test_failed_directory_swap_restores_previous_snapshot(self):
        rename = Path.rename

        def fail_install(path, target):
            if target == self.out and path.name == "new":
                raise OSError("cannot install")
            return rename(path, target)

        with patch.object(Path, "rename", fail_install):
            with self.assertRaisesRegex(OSError, "cannot install"):
                self.write_package(2)
        self.assert_snapshot(1)
        self.write_package(2)
        self.assert_snapshot(2)

    def test_refresh_replaces_snapshot_and_removes_obsolete_files(self):
        self.write_package(2)
        self.assert_snapshot(2)
        self.assertFalse((self.out / "packages/0x1.bcs").exists())
        self.assertEqual(list(self.out.parent.iterdir()), [self.out])


if __name__ == "__main__":
    unittest.main()
