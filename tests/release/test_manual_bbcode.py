"""Nexus manual conversion and publication handoff tests; no network or real editor."""
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import manual_bbcode as manual
import nexus_publish
import release
import release_archive
import steam_publish
from release_archive import ReleaseError


class ConversionTests(unittest.TestCase):
    def test_headings_lists_links_and_nested_emphasis(self):
        self.assertEqual(manual.convert(
            '## Usage\n\n- **Bold and *italic***\n- [Link](https://example.com)\n'),
            '[b][size=4]Usage[/size][/b]\n\n[list]\n'
            '[*][b]Bold and [i]italic[/i][/b][/*]\n'
            '[*][url=https://example.com]Link[/url][/*]\n[/list]\n')

    def test_nested_lists_loose_paragraphs_and_unicode(self):
        output = manual.convert('- Parent\n\n  More → text.\n\n  1. Child\n  2. 日本語\n')
        self.assertEqual(output, '[list]\n[*]Parent\n\nMore → text.\n\n'
                         '[list=1]\n[*]Child[/*]\n[*]日本語[/*]\n[/list][/*]\n[/list]\n')

    def test_line_wraps_breaks_and_colour(self):
        self.assertEqual(manual.convert('[color=#d4d4d8]One\ntwo  \n**three**[/color]'),
                         '[color=#d4d4d8]One two\n[b]three[/b][/color]\n')

    def test_unsupported_constructs_fail(self):
        for source in ('> quote', '```python\nx = 1\n```', '`code`',
                       '![image](https://example.com/image.png)', '<b>HTML</b>',
                       '---', '~~strike~~', '| A | B |\n|---|---|\n| a | b |',
                       '- [x] done', '[relative](other.md)', ''):
            with self.subTest(source=source), self.assertRaises(ReleaseError):
                manual.convert(source)

    def test_continued_numbered_list_preserves_numbers_and_formatting(self):
        self.assertEqual(manual.convert('3. **Third**\n4. Fourth\n'),
                         '3. [b]Third[/b]\n\n4. Fourth\n')

    def test_current_manual(self):
        source = (Path(__file__).resolve().parents[2] / manual.MANUAL).read_text(encoding='utf-8')
        output = manual.convert(source)
        # Structure only, so rewording the manual does not break the test.
        for pattern in (r'\A\[b\]\[size=5\].+?\[/size\]\[/b\]\n',
                        r'\[b\]\[size=4\].+?\[/size\]\[/b\]',
                        r'\[list\]\n\[\*\].+?\[/\*\]',
                        r'\[url=https://[^\]]+\].+?\[/url\]'):
            with self.subTest(pattern=pattern):
                self.assertRegex(output, pattern)
        self.assertNotIn('Work in progress', output)

    def test_handoff_writes_persistent_file_and_opens_notepad(self):
        with tempfile.TemporaryDirectory(prefix='manual with spaces ') as directory:
            with patch.object(manual, 'from_commit', return_value='[b]Released[/b]\n') as convert:
                with patch.object(manual.subprocess, 'Popen') as launch:
                    path = manual.handoff(directory, 'v1.2.3', 'abc123')
            convert.assert_called_once_with(directory, 'abc123')
            self.assertEqual(path.read_text(encoding='utf-8'), '[b]Released[/b]\n')
            launch.assert_called_once_with(['notepad.exe', str(path)])

    def test_handoff_rejects_unsafe_folder_names(self):
        for label in ('../escape', 'a/b', '', '.hidden'):
            with self.subTest(label=label), self.assertRaises(ReleaseError):
                manual.handoff('.', label, 'abc123')

    def test_editor_failure_keeps_output(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(manual, 'from_commit', return_value='Ready\n'):
                with patch.object(manual.subprocess, 'Popen', side_effect=OSError('No Notepad')):
                    with self.assertRaises(OSError):
                        manual.handoff(directory, 'v1.2.3', 'abc123')
            self.assertEqual((Path(directory) / 'dist/nexus/v1.2.3/description.bbcode.txt')
                             .read_text(encoding='utf-8'), 'Ready\n')


class ResolveTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.addCleanup(self.directory.cleanup)
        git = lambda *args: release_archive.git_bytes(self.root, *args).decode().strip()
        git('init', '-q', '-b', 'main')
        git('config', 'user.email', 'test@example.com')
        git('config', 'user.name', 'Test')
        (self.root / 'docs').mkdir()
        self.commits = []
        for text in ('# First\n', '# Second\n'):
            (self.root / manual.MANUAL).write_text(text, encoding='utf-8')
            git('add', manual.MANUAL)
            git('commit', '-q', '-m', text)
            self.commits.append(git('rev-parse', 'HEAD'))
        git('tag', 'v1.0.0', self.commits[0])
        git('branch', 'feature/new-docs', self.commits[1])

    def test_tag_keeps_release_folder(self):
        self.assertEqual(manual.resolve(self.root, 'v1.0.0'), (self.commits[0], 'v1.0.0'))

    def test_branch_and_commit_folders_pin_rendered_commit(self):
        commit = self.commits[1]
        self.assertEqual(manual.resolve(self.root, 'feature/new-docs'),
                         (commit, f'feature_new-docs-{commit[:10]}'))
        self.assertEqual(manual.resolve(self.root, 'HEAD~1'),
                         (self.commits[0], f'HEAD_1-{self.commits[0][:10]}'))

    def test_renders_manual_from_resolved_commit(self):
        commit, _ = manual.resolve(self.root, 'v1.0.0')
        self.assertEqual(manual.from_commit(self.root, commit), '[b][size=5]First[/size][/b]\n')

    def test_invalid_refs_fail(self):
        for ref in ('', '--all', 'missing-branch'):
            with self.subTest(ref=ref), self.assertRaises(ReleaseError):
                manual.resolve(self.root, ref)


class PublicationTests(unittest.TestCase):
    def invoke(self, command, *, publication_error=None, handoff_error=None, conversion_error=None,
               steam_enabled=False, steam_error=None):
        publisher = Mock()
        events = []
        steam = Mock(enabled=steam_enabled)
        self.steam = steam
        publisher.publish.side_effect = lambda *a, **kw: events.append('publish')
        if publication_error:
            publisher.publish.side_effect = publication_error
        self.publisher = publisher
        self.stderr = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(sys, 'argv', ['release.py', *command]))
            stack.enter_context(patch.object(nexus_publish, 'Publisher', return_value=publisher))
            stack.enter_context(patch.object(steam_publish, 'SteamPublisher', return_value=steam))
            self.publish_steam = stack.enter_context(patch.object(release, 'publish_steam',
                side_effect=steam_error or (lambda *a, **kw: events.append('steam'))))
            self.run_release = stack.enter_context(patch.object(release.Release, 'run',
                return_value=Path('dist/Example-Mod-1.2.3.zip')))
            stack.enter_context(patch.object(release_archive, 'tagged_zip',
                return_value=(Path('archive.zip'), 'released-commit', 'Notes')))
            self.local_zip = stack.enter_context(patch.object(release_archive, 'local_zip'))
            self.convert = stack.enter_context(patch.object(manual, 'from_commit',
                side_effect=conversion_error or (lambda *a: events.append('convert'))))
            self.handoff = stack.enter_context(patch.object(manual, 'handoff',
                side_effect=handoff_error or (lambda *a: events.append('handoff'))))
            stack.enter_context(contextlib.redirect_stderr(self.stderr))
            release.main()
        return events

    def test_release_and_resume_open_after_publication(self):
        for command in (['release'], ['publish-nexus', 'v1.2.3']):
            with self.subTest(command=command):
                self.assertEqual(self.invoke(command), ['convert', 'publish', 'handoff'])
                self.assertEqual(self.handoff.call_args.args[1:], ('v1.2.3', 'released-commit'))
                self.publisher.publish.assert_called_once()

    def test_publication_failure_never_opens_editor(self):
        with self.assertRaisesRegex(ReleaseError, 'Nexus publication incomplete'):
            self.invoke(['publish-nexus', 'v1.2.3'], publication_error=ReleaseError('Upload failed'))
        self.handoff.assert_not_called()

    def test_conversion_failure_before_publication(self):
        with self.assertRaisesRegex(ReleaseError, 'unsupported'):
            self.invoke(['publish-nexus', 'v1.2.3'], conversion_error=ReleaseError('unsupported'))
        self.publisher.publish.assert_not_called()
        self.handoff.assert_not_called()

    def test_handoff_failure_does_not_fail_or_retry_publication(self):
        for error in (OSError('Notepad missing'), ReleaseError('Conversion failed')):
            with self.subTest(error=error):
                self.invoke(['release'], handoff_error=error)
                self.publisher.publish.assert_called_once()
                self.assertIn('publication succeeded', self.stderr.getvalue())
                self.assertIn('just nexus-description v1.2.3', self.stderr.getvalue())

    def test_release_publishes_steam_after_nexus(self):
        self.assertEqual(self.invoke(['release'], steam_enabled=True), ['convert', 'publish', 'handoff', 'steam'])
        targets = self.run_release.call_args.kwargs['publisher'].publishers
        self.assertEqual(targets, (self.publisher, self.steam))

    def test_release_without_steam_config_skips_steam(self):
        self.assertEqual(self.invoke(['release']), ['convert', 'publish', 'handoff'])
        self.assertEqual(self.run_release.call_args.kwargs['publisher'].publishers, (self.publisher,))

    def test_nexus_failure_skips_steam_and_names_both_resumes(self):
        with self.assertRaisesRegex(ReleaseError, 'publish-nexus v1.2.3, then just publish-steam v1.2.3'):
            self.invoke(['release'], steam_enabled=True, publication_error=ReleaseError('Upload failed'))
        self.publish_steam.assert_not_called()

    def test_publish_steam_command_never_touches_nexus(self):
        self.assertEqual(self.invoke(['publish-steam', 'v1.2.3', '--retry-upload'], steam_enabled=True), ['steam'])
        self.assertEqual(self.publish_steam.call_args.args[1:], ('v1.2.3', self.steam, False, True, False))
        self.publisher.publish.assert_not_called()
        self.convert.assert_not_called()

    def test_build_zip_does_not_convert_or_open(self):
        self.assertEqual(self.invoke(['build-zip']), [])
        self.local_zip.assert_called_once()
        self.handoff.assert_not_called()


if __name__ == '__main__':
    unittest.main()
