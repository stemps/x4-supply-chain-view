"""Workshop staging and WorkshopTool publication tests. No network, no real WorkshopTool."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import workshop_build
from workshop_build import workshop_manifest, verify_catalog, stage
from steam_publish import SteamPublisher, update_command, change_note
from release_archive import ReleaseError

MANIFEST = (b'<?xml version="1.0" encoding="utf-8"?>\n'
            b'<content id="example_mod"\n  name="Example Mod"\n  version="100"\n  save="true">\n'
            b'  <text language="44" name="Example Mod" description="x" />\n'
            b'  <dependency version="900" name="X4: Foundations" />\n'
            b'  <dependency id="ws_2042901274" optional="false" name="Mod Support APIs" />\n'
            b'  <dependency id="kuerteeUIExtensionsAndHUD" optional="true" name="kuertee UI Extensions and HUD" />\n'
            b'</content>\n')
CONFIG = {'appid': 392160, 'published_file_id': '1234',
          'workshop_dependencies': {'kuerteeUIExtensionsAndHUD': 'ws_3477279743'}}


def fake_pack(root, source, catalog):
    """Write the Egosoft catalog format: 'path size mtime md5' plus concatenated data."""
    lines, data = [], b''
    for path in sorted(p for p in source.rglob('*') if p.is_file()):
        content = path.read_bytes()
        lines.append(f'{path.relative_to(source).as_posix()} {len(content)} 1700000000 '
                     f'{hashlib.md5(content).hexdigest()}')
        data += content
    catalog.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    catalog.with_suffix('.dat').write_bytes(data)


class ManifestTests(unittest.TestCase):
    def test_rewrites_id_adds_sync_and_workshop_twin(self):
        out = workshop_manifest(MANIFEST, '1234', CONFIG['workshop_dependencies'])
        self.assertIn(b'<content id="ws_1234"\n  name="Example Mod"\n  version="100"\n  save="true" sync="false">',
                      out)
        self.assertIn(b'id="kuerteeUIExtensionsAndHUD" optional="true"', out)
        self.assertIn(b'  <dependency id="ws_3477279743" optional="true" name="kuertee UI Extensions and HUD" />\n', out)
        # Nothing else changes.
        restored = out.replace(b'ws_1234"', b'example_mod"').replace(b' sync="false"', b'')
        restored = restored.replace(b'  <dependency id="ws_3477279743" optional="true" '
                                    b'name="kuertee UI Extensions and HUD" />\n', b'')
        self.assertEqual(restored, MANIFEST)

    def test_existing_sync_is_replaced_not_duplicated(self):
        out = workshop_manifest(MANIFEST.replace(b'save="true"', b'save="true" sync="true"'), '1234', {})
        self.assertEqual(out.count(b'sync='), 1)
        self.assertIn(b'sync="false"', out)

    def test_refusals(self):
        for item, deps, message in ((None, {}, 'published_file_id'),
                                    ('1234', {'Missing': 'ws_1'}, 'not declared'),
                                    ('1234', {'kuerteeUIExtensionsAndHUD': 'ws_2042901274'}, 'already declares')):
            with self.subTest(message=message), self.assertRaisesRegex(ReleaseError, message):
                workshop_manifest(MANIFEST, item, deps)

    def test_required_dependency_is_replaced_not_twinned(self):
        # A manifest cannot require one of two ids; Workshop players have the Workshop copy.
        required = MANIFEST.replace(b'id="kuerteeUIExtensionsAndHUD" optional="true"',
                                    b'id="kuerteeUIExtensionsAndHUD" optional="false"')
        out = workshop_manifest(required, '1234', {'kuerteeUIExtensionsAndHUD': 'ws_3477279743'})
        self.assertNotIn(b'kuerteeUIExtensionsAndHUD', out)
        self.assertIn(b'  <dependency id="ws_3477279743" optional="false" name="kuertee UI Extensions and HUD" />\n',
                      out)

    def test_live_manifest_and_config_are_compatible(self):
        root = Path(__file__).resolve().parents[2]
        cfg = workshop_build.config(root)
        out = workshop_manifest((root / 'src' / 'content.xml').read_bytes(), '1234', cfg['workshop_dependencies'])
        from xml.etree import ElementTree as ET
        parsed = ET.fromstring(out)
        self.assertEqual((parsed.get('id'), parsed.get('sync')), ('ws_1234', 'false'))

    def test_config_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertIsNone(workshop_build.config(root))
            for bad in ({**CONFIG, 'appid': 1}, {**CONFIG, 'published_file_id': 1234},
                        {**CONFIG, 'extra': True}, {**CONFIG, 'workshop_dependencies': {'a': '99'}}):
                (root / 'steam.json').write_text(json.dumps(bad), encoding='utf-8')
                with self.subTest(bad=bad), self.assertRaises(ReleaseError):
                    workshop_build.config(root)


class StageTests(unittest.TestCase):
    FILES = {'content.xml': MANIFEST, 'ui.xml': b'<addon/>\n', 'ui/a.lua': b'return 1\n',
             'md/a.xml': b'<mdscript/>\n', 'a.mkv': b'\x1aE\xdf\xa3video'}

    def stage(self, pack=fake_pack):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        destination = Path(self.temp.name) / 'out'
        return stage(Path(self.temp.name), sorted(self.FILES), self.FILES.__getitem__, destination, CONFIG, pack)

    def test_layout_content_xml_and_root_videos_loose_rest_packed(self):
        folder, digest = self.stage()
        self.assertEqual(folder.name, 'example_mod')
        loose = sorted(p.relative_to(folder).as_posix() for p in folder.rglob('*') if p.is_file())
        self.assertEqual(loose, ['a.mkv', 'content.xml', 'ext_01.cat', 'ext_01.dat'])
        self.assertEqual(set(workshop_build.parse_catalog(folder / 'ext_01.cat')), {'ui.xml', 'ui/a.lua', 'md/a.xml'})
        self.assertIn(b'id="ws_1234"', (folder / 'content.xml').read_bytes())
        self.assertEqual(digest, self.stage()[1], 'content digest must not depend on catalog mtimes')

    def test_catalog_that_drops_or_alters_a_file_fails(self):
        def dropping(root, source, catalog):
            (source / 'ui' / 'a.lua').unlink()
            fake_pack(root, source, catalog)

        def altering(root, source, catalog):
            (source / 'md' / 'a.xml').write_bytes(b'<changed/>\n')
            fake_pack(root, source, catalog)
        for pack, message in ((dropping, 'missing'), (altering, 'differs')):
            with self.subTest(message=message), self.assertRaisesRegex(ReleaseError, message):
                self.stage(pack)

    def test_dat_size_mismatch_fails(self):
        def truncated(root, source, catalog):
            fake_pack(root, source, catalog)
            catalog.with_suffix('.dat').write_bytes(b'short')
        with self.assertRaisesRegex(ReleaseError, 'wrong size'):
            self.stage(truncated)


@unittest.skipUnless(os.environ.get('XRCATTOOL') and Path(os.environ['XRCATTOOL']).is_file(),
                     'Set XRCATTOOL to run the real catalog round trip')
class RealXRCatToolTests(unittest.TestCase):
    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            files = StageTests.FILES
            folder, _ = stage(Path(directory), sorted(files), files.__getitem__, Path(directory) / 'out', CONFIG)
            extracted = Path(directory) / 'extracted'
            extracted.mkdir()  # XRCatTool refuses an output folder that does not exist yet.
            subprocess.run([os.environ['XRCATTOOL'], '-in', str(folder / 'ext_01.cat'), '-out', str(extracted)],
                           check=True, capture_output=True)
            for name in ('ui.xml', 'ui/a.lua', 'md/a.xml'):
                self.assertEqual((extracted / name).read_bytes(), files[name])


class FakeWorkshopTool:
    """Rewrites the staged manifest like WorkshopTool does after a successful upload."""
    def __init__(self, code=0, uploads=True, error=None, output=''):
        self.code, self.uploads, self.error, self.output, self.calls = code, uploads, error, output, []

    def __call__(self, command, **kwargs):
        self.calls.append((command, kwargs))
        if self.error:
            raise self.error
        if self.uploads:
            manifest = Path(command[command.index('-path') + 1]) / 'content.xml'
            manifest.write_bytes(manifest.read_bytes().replace(b'<content ', b'<content lastupdate="1" '))
        return subprocess.CompletedProcess(command, self.code, 'X Workshop Tool Version 1.15\n' + self.output, '')


class PublisherTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'steam.json').write_text(json.dumps(CONFIG), encoding='utf-8')
        self.folder = self.root / 'staged' / 'example_mod'
        self.folder.mkdir(parents=True)
        (self.folder / 'content.xml').write_bytes(b'<content id="ws_1234"></content>\n')
        self.tool = str(self.root / 'X Tools' / 'WorkshopTool.exe')
        tools = patch.object(workshop_build, 'tool', side_effect=lambda root, env, key, fallback:
                             self.tool if env == 'X4_WORKSHOPTOOL' else fallback)
        tools.start()
        self.addCleanup(tools.stop)

    def publisher(self, workshoptool, running=True):
        return SteamPublisher(self.root, run=workshoptool, clock=lambda: 100, running=lambda: running,
                              details=lambda item: {'result': 1, 'consumer_app_id': 392160})

    def publish(self, workshoptool, **flags):
        return self.publisher(workshoptool).publish('v1.2.3', 'commit', self.folder, 'digest', 'Notes', **flags)

    def receipt(self):
        return json.loads((self.root / 'dist' / 'steam' / 'v1.2.3.json').read_text(encoding='utf-8'))

    def test_success_records_receipt_log_and_is_idempotent(self):
        tool = FakeWorkshopTool()
        self.publish(tool)
        self.assertEqual(self.receipt()['upload_stage'], 'done')
        command, kwargs = tool.calls[0]
        self.assertEqual(command[:2], [self.tool, 'update'])
        self.assertIn('-batchmode', command)
        self.assertNotIn('-namedesc', command, 'updates must not overwrite the Workshop page text')
        self.assertNotIn('-minor', command)
        # steam_appid.txt beside the tool is read from the working directory.
        self.assertEqual(kwargs['cwd'], str(Path(self.tool).parent))
        self.assertTrue((self.root / 'dist' / 'steam' / 'v1.2.3.log').exists())
        self.publish(tool)
        self.assertEqual(len(tool.calls), 1, 'a completed release must not upload again')

    def test_minor_flag_and_changenote(self):
        command = update_command('WorkshopTool', self.folder, 'Line one\nLine two', True)
        self.assertEqual(command[command.index('-changenote') + 1], 'Line one\nLine two')
        self.assertEqual(command[-1], '-minor')

    def test_change_note_is_steam_bbcode_never_a_switch(self):
        tool = FakeWorkshopTool()
        self.publisher(tool).publish('v1.2.3', 'commit', self.folder, 'digest', '- First\n- Second **bold**')
        command = tool.calls[0][0]
        self.assertEqual(command[command.index('-changenote') + 1],
                         '[list]\n[*]First\n[*]Second [b]bold[/b]\n[/list]')
        with self.assertRaisesRegex(ReleaseError, "starting with '-'"):
            change_note('-flag-like paragraph')

    def test_unconvertible_notes_fail_preflight_before_tagging(self):
        import manual_bbcode
        with patch.object(manual_bbcode, 'from_commit'), self.assertRaisesRegex(ReleaseError, 'nsupported'):
            self.publisher(FakeWorkshopTool()).preflight('1.2.3', '> quoted')

    def test_argument_error_is_certain_and_retryable(self):
        with self.assertRaisesRegex(ReleaseError, 'nothing was uploaded'):
            self.publish(FakeWorkshopTool(905, uploads=False,
                                          output="ERROR: Parameter missing for switch 'changenote'\n"))
        self.assertEqual(self.receipt()['upload_stage'], 'pending')
        self.publish(FakeWorkshopTool())
        self.assertEqual(self.receipt()['upload_stage'], 'done')

    def test_unconfirmed_upload_requires_resolution(self):
        for tool in (FakeWorkshopTool(code=1, uploads=False), FakeWorkshopTool(code=0, uploads=False)):
            with self.subTest(code=tool.code):
                (self.root / 'dist' / 'steam' / 'v1.2.3.json').unlink(missing_ok=True)
                with self.assertRaisesRegex(ReleaseError, 'uncertain'):
                    self.publish(tool)
                self.assertEqual(self.receipt()['upload_stage'], 'sending')
        tool = FakeWorkshopTool()
        with self.assertRaisesRegex(ReleaseError, '--confirm-uploaded or --retry-upload'):
            self.publish(tool)
        self.assertEqual(tool.calls, [])
        self.publish(tool, retry=True)
        self.assertEqual(len(tool.calls), 1)
        self.assertEqual(self.receipt()['upload_stage'], 'done')

    def test_no_steam_connection_is_certain_and_retryable(self):
        with self.assertRaisesRegex(ReleaseError, 'nothing was uploaded'):
            self.publish(FakeWorkshopTool(903, uploads=False, output='ERROR: No connection to Steam servers\n'))
        self.assertEqual(self.receipt()['upload_stage'], 'pending')
        self.publish(FakeWorkshopTool())
        self.assertEqual(self.receipt()['upload_stage'], 'done')

    def test_timeout_is_uncertain_and_confirmable(self):
        with self.assertRaisesRegex(ReleaseError, 'uncertain'):
            self.publish(FakeWorkshopTool(error=subprocess.TimeoutExpired('WorkshopTool', 1)))
        tool = FakeWorkshopTool()
        self.publish(tool, confirm_uploaded=True)
        self.assertEqual(tool.calls, [])
        self.assertEqual(self.receipt()['upload_stage'], 'done')

    def test_flags_outside_uncertainty_and_changed_identity_refused(self):
        with self.assertRaisesRegex(ReleaseError, 'only to an uncertain'):
            self.publish(FakeWorkshopTool(), retry=True)
        self.publish(FakeWorkshopTool())
        with self.assertRaisesRegex(ReleaseError, 'differ from the saved receipt'):
            self.publisher(FakeWorkshopTool()).publish('v1.2.3', 'commit', self.folder, 'other', 'Notes')

    def test_missing_item_id_disables_releases_but_not_config(self):
        self.assertTrue(self.publisher(FakeWorkshopTool()).enabled)
        (self.root / 'steam.json').write_text(json.dumps({**CONFIG, 'published_file_id': None}), encoding='utf-8')
        publisher = SteamPublisher(self.root)
        self.assertIsNotNone(publisher.config)
        self.assertFalse(publisher.enabled)

    def test_release_preflight_checks_the_steam_manual(self):
        import manual_bbcode
        publisher = self.publisher(FakeWorkshopTool())
        with patch.object(manual_bbcode, 'from_commit', side_effect=ReleaseError('too long')) as convert, \
                patch('steam_publish.change_note'):
            publisher.preflight()  # Resumed uploads do not re-check the manual.
            convert.assert_not_called()
            with self.assertRaisesRegex(ReleaseError, 'too long'):
                publisher.preflight('1.2.3', 'Notes')
            convert.assert_called_once_with(self.root, 'HEAD', 'steam')

    def test_preflight_refuses_other_game_and_closed_steam(self):
        publisher = SteamPublisher(self.root, running=lambda: True,
                                   details=lambda item: {'result': 1, 'consumer_app_id': 1})
        with self.assertRaisesRegex(ReleaseError, 'different game'):
            publisher.preflight()
        tool = FakeWorkshopTool()
        with self.assertRaisesRegex(ReleaseError, 'Start the Steam client'):
            self.publisher(tool, running=False).publish('v1.2.3', 'commit', self.folder, 'digest', 'Notes')
        self.assertFalse((self.root / 'dist' / 'steam' / 'v1.2.3.json').exists(), 'nothing was attempted')
        self.assertEqual(tool.calls, [])


if __name__ == '__main__':
    unittest.main()
