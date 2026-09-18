"""Guard cross-file scope and addon order before exercising UI behavior."""
import tempfile
import unittest
from pathlib import Path

from addon_loader import validate_manifest
from lint_globals import analyze


class ModuleChecks(unittest.TestCase):
    def test_runtime_manifest(self):
        validate_manifest()

    def test_private_function_does_not_leak(self):
        self.assertEqual(analyze({'a': 'local function hidden() end', 'b': 'hidden()'}),
                         [('b', 1, 'hidden')])

    def test_parameter_does_not_leak(self):
        self.assertEqual(analyze({'a': 'function Public(callback) callback() end', 'b': 'callback()'}),
                         [('b', 1, 'callback')])

    def test_explicit_export_is_shared(self):
        self.assertEqual(analyze({'a': 'function Public() end', 'b': 'Public()'}), [])

    def test_comments_and_strings_do_not_define_helpers(self):
        source = '-- local function hidden() end\nlocal text = "local function hidden() end"\nhidden()'
        self.assertEqual(analyze({'a': source}), [('a', 3, 'hidden')])
        self.assertEqual(analyze({'a': 'local x = "--"; missing()'}), [('a', 1, 'missing')])

    def test_long_literals_and_newlines(self):
        source = '--[=[\nnotACall()\n]=]\nlocal s=[==[alsoNotACall()]==]\nmissing()'
        self.assertEqual(analyze({'a': source}), [('a', 5, 'missing')])

    def test_missing_duplicate_and_reordered_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'ui').mkdir()
            (root / 'ui/a.lua').write_text('A = {}')
            (root / 'ui/b.lua').write_text('-- Depends: a.lua\nB = {}')
            for names in [('b', 'a'), ('a', 'b', 'b'), ('a',)]:
                (root / 'ui.xml').write_text('<addon><environment>' + ''.join(
                    f'<file name="ui/{name}.lua"/>' for name in names) + '</environment></addon>')
                with self.assertRaises(AssertionError):
                    validate_manifest(root)


if __name__ == '__main__':
    unittest.main()
