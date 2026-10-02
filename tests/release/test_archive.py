"""Archive behavior using isolated Git repositories; never access Nexus."""
import hashlib
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from release_archive import local_zip, tagged_zip, ReleaseError
from release_support import ReleaseFixture

REPO = Path(__file__).resolve().parents[2]


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.fixture = ReleaseFixture()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root

    def test_current_manifest_modules_are_included(self):
        from xml.etree import ElementTree as ET
        modules = [node.attrib['name'] for node in ET.parse(REPO / 'src/ui.xml').iter('file')]
        self.assertTrue(modules)
        self.fixture.write('src/ui.xml', (REPO / 'src/ui.xml').read_text(encoding='utf-8'))
        for name in modules:
            self.fixture.write('src/' + name, (REPO / 'src' / name).read_text(encoding='utf-8'))
        # This archive exists only in the fixture's temporary repository.
        archive = local_zip(self.root)
        with zipfile.ZipFile(archive) as zipped:
            for name in modules:
                self.assertEqual(zipped.read('example_mod/' + name),
                                 (self.root / 'src' / name).read_bytes())

    def test_shipped_license_matches_repository_license(self):
        # GitHub reads the root copy; players get the src copy. They must not drift.
        self.assertEqual((REPO / 'src/MIT-LICENSE').read_bytes(), (REPO / 'MIT-LICENSE').read_bytes())

    def test_dirty_new_deleted_ignored_and_excluded(self):
        f = self.fixture
        f.cmd('checkout', '-b', 'experiment')
        f.write('src/ui/example.lua', 'return 42\n')
        f.write('src/ui/new.lua', 'return 3\n')
        f.write('.gitignore', '/dist/\nsrc/ui/ignored.lua\n')
        f.write('src/ui/ignored.lua', 'return 4\n')
        (self.root / 'src/t/0001.xml').unlink()
        before = f.cmd('status', '--porcelain')
        commit = f.cmd('rev-parse', 'HEAD')
        metadata = (self.root / 'src/content.xml').read_bytes()
        archive = local_zip(self.root)
        with zipfile.ZipFile(archive) as zipped:
            self.assertEqual(set(zipped.namelist()), {'example_mod/' + p for p in
                             ['content.xml', 'ui.xml', 'ui/example.lua', 'ui/new.lua']})
            self.assertEqual(zipped.read('example_mod/ui/example.lua'), b'return 42\n')
        self.assertEqual(f.cmd('status', '--porcelain'), before)
        self.assertEqual(f.cmd('rev-parse', 'HEAD'), commit)
        self.assertEqual((self.root / 'src/content.xml').read_bytes(), metadata)
        self.assertFalse((self.root / 'VERSION').exists())

    def test_replace_only_after_success(self):
        archive = local_zip(self.root)
        original = archive.read_bytes()
        self.fixture.write('src/ui/example.lua', 'return 10\n')
        with patch('release_archive.verify_zip', side_effect=ReleaseError('invalid archive')):
            with self.assertRaises(ReleaseError):
                local_zip(self.root)
        self.assertEqual(archive.read_bytes(), original)
        local_zip(self.root)
        self.assertNotEqual(archive.read_bytes(), original)

    def test_every_src_file_ships_and_nothing_outside(self):
        inside = ('ce_news_raid.mkv', 'MIT-LICENSE', 'md/ce_logistics.xml', 'aiscripts/order.plunder.xml',
                  'assets/textures/ui/factions/ce_unrest_skull.gz', 'index/macros.xml',
                  'extensions/optional_mod/md/integration.xml', 'cutscenes/notes.txt')
        outside = ('md/stray.xml', 'ui/stray.lua', 'tools/probe.lua', 'images/ce_unrest_skull.png',
                   'docs/example.xml', 'README.md', 'MIT-LICENSE', 'root_patch.xml')
        for name in inside:
            self.fixture.write('src/' + name, 'synthetic ' + name)
        for name in outside:
            self.fixture.write(name, 'outside')
        with zipfile.ZipFile(local_zip(self.root)) as archive:
            expected = {'content.xml', 't/0001.xml', 'ui.xml', 'ui/example.lua', *inside}
            self.assertEqual(set(archive.namelist()), {'example_mod/' + name for name in expected})
            for name in inside:
                self.assertEqual(archive.read('example_mod/' + name), ('synthetic ' + name).encode())

    def test_src_content_in_local_release_and_tagged_archives(self):
        paths = ('src/md/ce_logistics.xml', 'src/libraries/constructionplans.xml', 'src/ce_news_raid.mkv')
        for name in paths:
            self.fixture.write(name, '<diff/>\n')
        local = local_zip(self.root)
        with zipfile.ZipFile(local) as archive:
            for name in paths:
                self.assertEqual(archive.read('example_mod/' + name[4:]), b'<diff/>\n')
        self.fixture.cmd('add', '--', *paths)
        self.fixture.cmd('commit', '-m', 'Add runtime content')
        self.fixture.cmd('push', 'origin', 'main')  # fixture's temporary local bare repo
        public = self.fixture.run_release()
        expected = public.read_bytes()
        with zipfile.ZipFile(public) as archive:
            for name in paths:
                self.assertEqual(archive.read('example_mod/' + name[4:]), b'<diff/>\n')
        public.unlink()
        rebuilt, _, _ = tagged_zip(self.root, 'v0.1.0')
        self.assertEqual(rebuilt.read_bytes(), expected)

    def test_missing_manifest_fails(self):
        (self.root / 'src/ui.xml').unlink()
        with self.assertRaisesRegex(ReleaseError, 'Missing runtime manifests'):
            local_zip(self.root)

    def test_tag_reconstruction_is_identical_and_ignores_worktree(self):
        archive = self.fixture.run_release()
        expected = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.fixture.write('src/ui/example.lua', 'uncommitted code')
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
            path = self.root / 'src' / name
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
            zipped.writestr('example_mod/ui/extra.lua', b'bad')
        with self.assertRaises(ReleaseError):
            tagged_zip(self.root, 'v0.1.0')


if __name__ == '__main__':
    unittest.main()
