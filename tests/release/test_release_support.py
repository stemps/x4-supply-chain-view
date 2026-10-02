"""Real Git fixture copies must never share writable repository state."""
from pathlib import Path
import unittest
from release_support import ReleaseFixture


class FixtureIsolationTests(unittest.TestCase):
    def fixture(self):
        fixture = ReleaseFixture()
        self.addCleanup(fixture.doCleanups)
        fixture.setUp()
        return fixture

    def test_worktrees_config_hooks_objects_and_remotes_are_independent(self):
        first = self.fixture()
        original = first.cmd('rev-parse', 'HEAD')
        first.write('src/ui/example.lua', 'return 42\n')
        first.cmd('commit', '-am', 'Only in first fixture')
        first.cmd('tag', 'isolation-tag')
        first.cmd('push', 'origin', 'HEAD:isolated', '--tags')
        first.cmd('config', 'core.autocrlf', 'true')
        first.write('.git/hooks/pre-commit', '#!/bin/sh\nexit 1\n')
        first.write('untracked.txt', 'first only')
        # Create the other copy AFTER modifying the first, to exercise the seed.
        second = self.fixture()
        self.assertEqual(second.cmd('rev-parse', 'HEAD'), original)
        self.assertEqual(second.cmd('status', '--porcelain'), '')
        self.assertEqual(second.cmd('tag', '--list'), '')
        self.assertEqual(second.cmd('config', 'core.autocrlf'), 'false')
        self.assertEqual(Path(second.cmd('remote', 'get-url', 'origin')), second.remote)
        self.assertEqual((second.root / 'src/ui/example.lua').read_text(), 'return 1\n')
        self.assertFalse((second.root / 'untracked.txt').exists())
        self.assertFalse((second.root / '.git/hooks/pre-commit').exists())
        self.assertFalse((second.root / '.git/objects/info/alternates').exists())
        self.assertEqual(second.cmd('ls-remote', '--heads', 'origin', 'isolated'), '')
        self.assertEqual(second.cmd('ls-remote', '--tags', 'origin'), '')
        object_path = Path('.git/objects') / original[:2] / original[2:]
        self.assertFalse((first.root / object_path).samefile(second.root / object_path))
        second.write('src/ui/example.lua', 'return 9\n')
        second.cmd('commit', '-am', 'Only in second fixture')
        second.cmd('push')
        self.assertEqual(first.cmd('rev-parse', 'origin/main'), original)


if __name__ == '__main__':
    unittest.main()
