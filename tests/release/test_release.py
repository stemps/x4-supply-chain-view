"""Release integration tests. All pushes target disposable local bare repositories."""
import os
import subprocess
import unittest
from unittest.mock import patch
import zipfile
from release_support import ReleaseFixture, release


class ReleaseTests(ReleaseFixture):
    def test_default_gate_keeps_release_integration_and_rolls_back_on_failure(self):
        original_run = subprocess.run
        original_manifest = (self.root / 'src/content.xml').read_bytes()
        gates = []

        def run(command, **kwargs):
            if command[0] == 'just':
                gates.append(command)
                raise subprocess.CalledProcessError(1, command)
            return original_run(command, **kwargs)

        with patch.object(release.subprocess, 'run', side_effect=run):
            with self.assertRaises(subprocess.CalledProcessError):
                self.runner.run(ask=lambda _: '0.1.0')
        self.assertEqual(gates, [['just', 'check-release']])
        self.assertEqual((self.root / 'src/content.xml').read_bytes(), original_manifest)
        self.assertEqual(self.cmd('status', '--porcelain'), '')
        self.assertEqual(self.cmd('tag', '--list'), '')

    def test_first_and_subsequent_release(self):
        archive = self.run_release()
        self.assertEqual(archive.name, "Example-Mod-0.1.0.zip")
        self.assertEqual(self.cmd("status", "--porcelain"), "")
        self.assertEqual((self.root / "VERSION").read_text().strip(), "0.1.0")
        manifest = (self.root / "src/content.xml").read_text(encoding="utf-8")
        self.assertIn('version="100"', manifest)
        self.assertIn('name="日本語"', manifest)
        self.assertEqual(self.cmd("rev-parse", "HEAD"), self.cmd("rev-parse", "origin/main"))
        self.assertEqual(self.cmd("cat-file", "-t", "v0.1.0"), "tag")
        with zipfile.ZipFile(archive) as zipped:
            self.assertFalse(any(name.startswith("example_mod/assets/") for name in zipped.namelist()))
            self.assertEqual(set(zipped.namelist()), {"example_mod/" + p for p in
                             ("content.xml", "ui.xml", "ui/example.lua", "t/0001.xml")})
            for name in zipped.namelist():
                blob = subprocess.run(["git", "show", "v0.1.0:src/" + name.split("/", 1)[1]],
                                      cwd=self.root, capture_output=True, check=True).stdout
                self.assertEqual(zipped.read(name), blob)
        self.write("src/ui/example.lua", "return 2\n")
        self.cmd("commit", "-am", "Improve graph")
        self.cmd("push")
        self.assertEqual(self.runner.notes("v0.1.0"), "- Improve graph")
        self.run_release()
        changelog = (self.root / "CHANGELOG.md").read_text()
        self.assertLess(changelog.index("## 0.2.0"), changelog.index("## 0.1.0"))
        self.assertEqual(changelog.count("Initial mod"), 1)

    def test_first_release_advances_existing_manifest(self):
        self.write('src/content.xml', '<content version="300" date="2026-09-20"/>')
        self.assertEqual(self.runner.previous(), (None, '0.4.0'))
        self.write('src/content.xml', '<content version="19999" date="2026-09-20"/>')
        self.assertEqual(self.runner.previous(), (None, '2.0.0'))

    def test_preflight_rejections(self):
        self.cmd("checkout", "-b", "feature")
        with self.assertRaises(release.ReleaseError): self.runner.preflight()
        self.cmd("checkout", "main")
        self.write("untracked", "x")
        with self.assertRaises(release.ReleaseError): self.runner.preflight()
        (self.root / "untracked").unlink()
        self.write("README.md", "dirty")
        with self.assertRaises(release.ReleaseError): self.runner.preflight()
        self.cmd("add", "README.md")
        with self.assertRaises(release.ReleaseError): self.runner.preflight()
        self.cmd("commit", "-m", "Unpushed")
        with self.assertRaises(release.ReleaseError): self.runner.preflight()
        self.cmd("push")
        self.cmd("branch", "--unset-upstream")
        with self.assertRaises(release.ReleaseError): self.runner.preflight()
        self.cmd("branch", "--set-upstream-to=origin/main")
        self.cmd("remote", "set-url", "origin", str(self.remote.parent / "missing.git"))
        with self.assertRaises(release.ReleaseError): self.runner.preflight()

    def test_manual_uses_released_commit_after_later_edits(self):
        from manual_bbcode import from_commit
        commit = self.cmd('rev-parse', 'HEAD')
        self.write('docs/MANUAL.md', '## Later working-tree edits\n')
        self.assertIn('Release manual.', from_commit(self.root, commit))
        self.assertNotIn('Later working-tree', from_commit(self.root, commit))

    def test_invalid_manual_stops_before_metadata_or_publication(self):
        self.write('docs/MANUAL.md', '> Unsupported quote\n')
        self.cmd('commit', '-am', 'Unsupported manual')
        self.cmd('push')
        head = self.cmd('rev-parse', 'HEAD')
        with patch.object(self.runner, 'updated_metadata') as update:
            with self.assertRaisesRegex(release.ReleaseError, 'unsupported Markdown'):
                self.run_release()
        update.assert_not_called()
        self.assertEqual(self.cmd('rev-parse', 'HEAD'), head)
        self.assertEqual(self.cmd('status', '--porcelain'), '')

    def test_remote_ahead(self):
        old = self.cmd("rev-parse", "HEAD")
        self.cmd("commit", "--allow-empty", "-m", "Remote addition")
        self.cmd("push")
        self.cmd("reset", "--hard", old)
        with self.assertRaises(release.ReleaseError): self.runner.preflight()

    def test_invalid_versions_and_collisions(self):
        for value in ("1.0", "v1.0.0", "01.0.0", "1.100.0", "1.0.100", "1.0.0-beta"):
            with self.subTest(value=value), self.assertRaises(release.ReleaseError):
                self.run_release(value)
        self.run_release()
        for value in ("0.1.0", "0.0.9"):
            with self.assertRaises(release.ReleaseError): self.run_release(value)
        self.cmd("tag", "v0.2.0")
        with self.assertRaises(release.ReleaseError): self.run_release("0.2.0")

    def test_existing_zip(self):
        self.write("dist/Example-Mod-0.1.0.zip", "keep")
        with self.assertRaises(release.ReleaseError): self.run_release()
        self.assertEqual((self.root / "dist/Example-Mod-0.1.0.zip").read_text(), "keep")

    # GIT_EDITOR/VISUAL/EDITOR outrank core.editor; clear them so the configured one runs.
    @patch.dict(os.environ, {"GIT_EDITOR": "", "VISUAL": "", "EDITOR": ""})
    def test_editor_arguments_empty_and_failure(self):
        self.cmd("config", "core.editor", "sh -c 'printf -- " + '"- Edited notes\\n"' + " > \"$1\"' editor")
        self.assertEqual(self.runner.notes(None), "- Edited notes")
        self.cmd("config", "core.editor", "sh -c '> \"$1\"' editor")
        with self.assertRaises(release.ReleaseError): self.run_release()
        self.cmd("config", "core.editor", "false")
        with self.assertRaises(release.ReleaseError): self.run_release()
        self.assertFalse((self.root / "VERSION").exists())

    def test_check_failure_rolls_back(self):
        original = (self.root / "src/content.xml").read_bytes()
        def fail(): raise release.ReleaseError("checks failed")
        with self.assertRaises(release.ReleaseError): self.run_release(check=fail)
        self.assertEqual((self.root / "src/content.xml").read_bytes(), original)
        self.assertEqual(self.cmd("status", "--porcelain"), "")

    def test_archive_failure_rolls_back(self):
        with patch.object(self.runner, "build_zip", side_effect=release.ReleaseError("bad archive")):
            with self.assertRaises(release.ReleaseError): self.run_release()
        self.assertEqual(self.cmd("status", "--porcelain"), "")
        self.assertEqual(self.cmd("tag", "--list"), "")

    def test_nexus_preflight_failure_precedes_metadata_changes(self):
        from unittest.mock import Mock
        publisher = Mock()
        publisher.preflight.side_effect = release.ReleaseError('Nexus rejected credentials')
        original = (self.root / 'src/content.xml').read_bytes()
        with self.assertRaisesRegex(release.ReleaseError, 'credentials'):
            self.runner.run(ask=lambda _: '0.1.0', check=lambda: None, publisher=publisher)
        publisher.preflight.assert_called_once_with('0.1.0', '- Initial mod')
        self.assertEqual((self.root / 'src/content.xml').read_bytes(), original)
        self.assertFalse((self.root / 'VERSION').exists())
        self.assertEqual(self.cmd('status', '--porcelain'), '')

    def test_commit_failure_unstages_and_rolls_back(self):
        self.write(".git/hooks/pre-commit", "#!/bin/sh\nexit 1\n")
        (self.root / ".git/hooks/pre-commit").chmod(0o755)
        with self.assertRaises(release.ReleaseError): self.run_release()
        self.assertEqual(self.cmd("status", "--porcelain"), "")
        self.assertEqual(self.cmd("tag", "--list"), "")

    def test_windows_line_endings(self):
        self.cmd("config", "core.autocrlf", "true")
        for name in ("content.xml", "ui.xml", "ui/example.lua", "t/0001.xml"):
            path = self.root / "src" / name
            path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        self.cmd("add", "--renormalize", ".")
        self.assertEqual(self.cmd("status", "--porcelain"), "")
        self.assertTrue(self.run_release().exists())

    def test_concurrent_edits_preserved(self):
        def change(): self.write("README.md", "concurrent edit")
        with self.assertRaises(release.ReleaseError): self.run_release(check=change)
        self.assertEqual((self.root / "README.md").read_text(), "concurrent edit")
        self.assertFalse((self.root / "VERSION").exists())

    def test_concurrent_metadata_preserved(self):
        def change(): self.write("VERSION", "someone else's edit\n")
        with self.assertRaises(release.ReleaseError): self.run_release(check=change)
        self.assertEqual((self.root / "VERSION").read_text(), "someone else's edit\n")

    def test_rejected_push_retains_release(self):
        hook = self.remote / "hooks" / "pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        before = self.cmd("rev-parse", "origin/main")
        with self.assertRaises(release.ReleaseError): self.run_release()
        self.assertEqual(self.cmd("tag", "--list"), "v0.1.0")
        self.assertEqual(self.cmd("log", "-1", "--format=%s"), "Release v0.1.0")
        self.assertEqual(self.cmd("rev-parse", "origin/main"), before)
        self.assertFalse((self.root / "dist").exists())
        self.assertEqual(self.cmd("status", "--porcelain"), "")


if __name__ == "__main__":
    unittest.main()
