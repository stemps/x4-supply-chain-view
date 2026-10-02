"""Disposable local Git repositories shared by release-tooling tests."""
import importlib.util
import atexit
from functools import lru_cache
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))

spec = importlib.util.spec_from_file_location("ce_release", Path(__file__).resolve().parents[2] / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


@lru_cache(maxsize=1)
def seed_repository():
    """One pristine seed per process; tests receive independent ordinary copies."""
    temp = tempfile.TemporaryDirectory(prefix='release-seed-')
    fixture = ReleaseFixture()
    fixture.root = Path(temp.name) / 'mod'
    fixture.remote = Path(temp.name) / 'origin.git'
    try:
        fixture.initialize_repository()
    except BaseException:
        temp.cleanup()
        raise
    atexit.register(temp.cleanup)
    return Path(temp.name)


class ReleaseFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.root = base / "mod"
        self.remote = base / "origin.git"
        self.env = patch.dict(os.environ, {"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                                           "GIT_TERMINAL_PROMPT": "0"})
        self.env.start()
        self.addCleanup(self.env.stop)
        seed = seed_repository()
        # copytree copies file contents, including Git objects; no shared mutable
        # state, alternates or hardlinks survive into a test's repositories.
        shutil.copytree(seed / 'mod', self.root)
        shutil.copytree(seed / 'origin.git', self.remote)
        self.cmd('remote', 'set-url', 'origin', str(self.remote))
        self.runner = release.Release(self.root)

    def initialize_repository(self):
        self.root.mkdir()
        self.cmd("init", "--bare", str(self.remote))
        self.cmd("init", "-b", "main")
        self.cmd("config", "user.name", "Release Test")
        self.cmd("config", "user.email", "release@example.invalid")
        self.cmd("config", "core.autocrlf", "false")
        self.cmd("config", "core.editor", "true")
        self.write(".gitignore", "/dist/\n")
        self.write("src/content.xml", '<content id="example_mod" name="Example Mod" version="0" date="2026-09-06">\n<text name="日本語"/>\n</content>\n')
        self.write("src/ui.xml", "<addon/>\n")
        self.write("src/ui/example.lua", "return 1\n")
        self.write("src/t/0001.xml", "<language/>\n")
        self.write("test/excluded.lua", "return 0\n")
        self.write("images/nested/example.xml", "<promotional/>\n")
        self.write("README.md", "Not shipped\n")
        self.write("docs/MANUAL.md", "## Usage\n\nRelease manual.\n")
        self.cmd("add", ".")
        self.cmd("commit", "-m", "Initial mod")
        self.cmd("remote", "add", "origin", str(self.remote))
        self.cmd("push", "-u", "origin", "main")

    def cmd(self, *args):
        result = subprocess.run(["git", *args], cwd=self.root, capture_output=True, check=True)
        return result.stdout.decode().strip()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")

    def run_release(self, version="", check=lambda: None):
        return self.runner.run(ask=lambda _: version, check=check)

