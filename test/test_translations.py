"""Regression tests for full translation coverage; no game/runtime dependencies."""
from pathlib import Path
import tempfile
import unittest

from check_sources import translation_coverage_errors


class TranslationCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = '<page id="90210"><t id="1">Stations</t></page>'
        self.source += '<page id="90211"><t id="1">%s/h</t></page>'
        self.write("0001.xml", self.source)
        self.write("0001-l049.xml", self.source)

    def write(self, name, body):
        (self.root / name).write_text(f"<language>{body}</language>", encoding="utf-8")

    def errors(self):
        return translation_coverage_errors(self.root, {49})

    def test_complete_multiple_pages_and_shared_words_pass(self):
        self.assertEqual(self.errors(), [])

    def test_missing_entry_on_second_page_is_reported(self):
        self.write("0001-l049.xml", '<page id="90210"><t id="1">Stationen</t></page>')
        self.assertEqual(self.errors(), [
            "0001-l049.xml: page 90211, text 1: missing translation"])

    def test_missing_language_file_fails(self):
        (self.root / "0001-l049.xml").unlink()
        self.assertIn("0001-l049.xml: missing language file", self.errors())

    def test_empty_translation_fails(self):
        self.write("0001-l049.xml", self.source.replace("Stations", " \n "))
        self.assertTrue(any("empty translation" in error for error in self.errors()))

    def test_duplicate_entry_fails(self):
        self.write("0001-l049.xml", self.source + self.source)
        self.assertEqual(sum("duplicate entry" in error for error in self.errors()), 2)

    def test_all_languages_are_reported_together(self):
        self.write("0001-l033.xml", '<page id="90210"><t id="1">Stations</t></page>')
        self.write("0001-l049.xml", '<page id="90211"><t id="1">%s/h</t></page>')
        self.assertEqual(sum("missing translation" in error for error in self.errors()), 2)

    def test_malformed_xml_is_reported(self):
        (self.root / "0001-l049.xml").write_text("<language>", encoding="utf-8")
        self.assertTrue(any("no element found" in error for error in self.errors()))

    def test_extra_entry_fails(self):
        self.write("0001-l049.xml", self.source + '<page id="99"><t id="2">Extra</t></page>')
        self.assertTrue(any("absent from neutral source" in error for error in self.errors()))


if __name__ == "__main__":
    unittest.main()
