"""Archive behavior using isolated Git repositories; never access Nexus."""
import hashlib
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from release_archive import local_zip, tagged_zip, ReleaseError
import test_release


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_release.ReleaseTests('test_first_and_subsequent_release')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root

    def test_current_manifest_modules_are_included(self):
        from addon_loader import ROOT, module_order, validate_manifest
        validate_manifest()
        self.fixture.write('ui.xml', (ROOT / 'ui.xml').read_text(encoding='utf-8'))
        for name in module_order():
            self.fixture.write(name, (ROOT / name).read_text(encoding='utf-8'))
        # This archive exists only in the fixture's temporary repository.
        archive = local_zip(self.root)
        with zipfile.ZipFile(archive) as zipped:
            for name in module_order():
                self.assertEqual(zipped.read('supply_chain_view/' + name),
                                 (self.root / name).read_bytes())

    def test_dirty_new_deleted_ignored_and_excluded(self):
        f = self.fixture
        f.cmd('checkout', '-b', 'experiment')
        f.write('ui/example.lua', 'return 42\n')
        f.write('ui/new.lua', 'return 3\n')
        f.write('.gitignore', '/dist/\nui/ignored.lua\n')
        f.write('ui/ignored.lua', 'return 4\n')
        (self.root / 't/0001.xml').unlink()
        before = f.cmd('status', '--porcelain')
        commit = f.cmd('rev-parse', 'HEAD')
        metadata = (self.root / 'content.xml').read_bytes()
        archive = local_zip(self.root)
        with zipfile.ZipFile(archive) as zipped:
            self.assertEqual(set(zipped.namelist()), {'supply_chain_view/' + p for p in
                             ['content.xml', 'ui.xml', 'ui/example.lua', 'ui/new.lua']})
            self.assertEqual(zipped.read('supply_chain_view/ui/example.lua'), b'return 42\n')
        self.assertEqual(f.cmd('status', '--porcelain'), before)
        self.assertEqual(f.cmd('rev-parse', 'HEAD'), commit)
        self.assertEqual((self.root / 'content.xml').read_bytes(), metadata)
        self.assertFalse((self.root / 'VERSION').exists())

    def test_replace_only_after_success(self):
        archive = local_zip(self.root)
        original = archive.read_bytes()
        self.fixture.write('ui/example.lua', 'return 10\n')
        with patch('release_archive.verify_zip', side_effect=ReleaseError('invalid archive')):
            with self.assertRaises(ReleaseError):
                local_zip(self.root)
        self.assertEqual(archive.read_bytes(), original)
        local_zip(self.root)
        self.assertNotEqual(archive.read_bytes(), original)

    def test_md_in_local_release_and_tagged_archives(self):
        self.fixture.write('md/scv_logistics.xml', '<mdscript name="SCV_Logistics"/>\n')
        self.fixture.write('md/notes.txt', 'Not runtime content')
        local = local_zip(self.root)
        with zipfile.ZipFile(local) as archive:
            self.assertIn('supply_chain_view/md/scv_logistics.xml', archive.namelist())
            self.assertNotIn('supply_chain_view/md/notes.txt', archive.namelist())
        self.fixture.cmd('add', 'md')
        self.fixture.cmd('commit', '-m', 'Add MD reader')
        self.fixture.cmd('push', 'origin', 'main')  # fixture's temporary local bare repo
        public = self.fixture.run_release()
        with zipfile.ZipFile(public) as archive:
            expected = archive.read('supply_chain_view/md/scv_logistics.xml')
        public.unlink()
        rebuilt, _, _ = tagged_zip(self.root, 'v0.1.0')
        with zipfile.ZipFile(rebuilt) as archive:
            self.assertEqual(archive.read('supply_chain_view/md/scv_logistics.xml'), expected)

    def test_missing_manifest_fails(self):
        (self.root / 'ui.xml').unlink()
        with self.assertRaisesRegex(ReleaseError, 'Missing runtime manifests'):
            local_zip(self.root)

    def test_tag_reconstruction_is_identical_and_ignores_worktree(self):
        archive = self.fixture.run_release()
        expected = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.fixture.write('ui/example.lua', 'uncommitted code')
        before = self.fixture.cmd('status', '--porcelain')
        archive.unlink()
        rebuilt, commit, notes = tagged_zip(self.root, 'v0.1.0')
        self.assertEqual(hashlib.sha256(rebuilt.read_bytes()).hexdigest(), expected)
        self.assertEqual(commit, self.fixture.cmd('rev-parse', 'v0.1.0^{}'))
        self.assertEqual(notes, '- Initial mod')
        self.assertEqual(self.fixture.cmd('status', '--porcelain'), before)

    def test_windows_release_reconstruction(self):
        f = self.fixture
        f.cmd('config', 'core.autocrlf', 'true')
        for name in ('content.xml', 'ui.xml', 'ui/example.lua', 't/0001.xml'):
            path = self.root / name
            path.write_bytes(path.read_bytes().replace(b'\n', b'\r\n'))
        f.cmd('add', '--renormalize', '.')
        archive = f.run_release()
        expected = archive.read_bytes()
        archive.unlink()
        rebuilt, _, _ = tagged_zip(self.root, 'v0.1.0')
        self.assertEqual(rebuilt.read_bytes(), expected)

    def test_remote_tag_mismatch_rejected(self):
        self.fixture.run_release()
        self.fixture.cmd('tag', '-f', '-a', 'v0.1.0', '-m', 'changed')
        with self.assertRaisesRegex(ReleaseError, 'tags do not match'):
            tagged_zip(self.root, 'v0.1.0')

    def test_existing_archive_tampering_rejected(self):
        archive = self.fixture.run_release()
        with zipfile.ZipFile(archive, 'a') as zipped:
            zipped.writestr('supply_chain_view/ui/extra.lua', b'bad')
        with self.assertRaises(ReleaseError):
            tagged_zip(self.root, 'v0.1.0')


if __name__ == '__main__':
    unittest.main()
