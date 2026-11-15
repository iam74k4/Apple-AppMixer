"""scripts/asc.py のうち、App Store Connect に繋がずに試せるところのテスト。

    python3 -m unittest discover -s scripts -p 'test_*.py'   # make test から呼ばれる
"""

import os
import sys
import tempfile
import types
import unittest

# 認証（JWT を作るところ）は試さないので、PyJWT が無い手元でも読み込めるようにする。
sys.modules.setdefault("jwt", types.ModuleType("jwt"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import asc  # noqa: E402

JA = "・日本語の変更点です。"
EN = "- English notes."


class NotesForLocaleTests(unittest.TestCase):
    def test_japanese_page_gets_changelog(self):
        self.assertEqual(asc.notes_for_locale("ja", JA, EN), JA)

    def test_english_pages_get_english_notes(self):
        for locale in ("en-US", "en-CA", "en-GB", "en-AU"):
            with self.subTest(locale=locale):
                self.assertEqual(asc.notes_for_locale(locale, JA, EN), EN)

    def test_english_page_never_falls_back_to_japanese(self):
        self.assertIsNone(asc.notes_for_locale("en-US", JA, None))
        self.assertIsNone(asc.notes_for_locale("en-US", JA, ""))

    def test_other_locales_get_changelog(self):
        self.assertEqual(asc.notes_for_locale("fr-FR", JA, EN), JA)

    def test_nothing_to_put(self):
        self.assertIsNone(asc.notes_for_locale("ja", None, EN))
        self.assertIsNone(asc.notes_for_locale(None, None, None))


class SetWhatsNewTests(unittest.TestCase):
    """api() を差し替えて、どのロケールに何を書きに行くかを見る。"""

    def setUp(self):
        self.patched = []
        self.original_api = asc.api
        self.original_log = asc.log
        asc.log = lambda message: None

        localizations = [
            {"id": "loc-ja", "attributes": {"locale": "ja", "whatsNew": None}},
            {"id": "loc-us", "attributes": {"locale": "en-US", "whatsNew": ""}},
            {"id": "loc-ca", "attributes": {"locale": "en-CA", "whatsNew": "Written by hand."}},
        ]

        def fake_api(method, path, body=None, params=None):
            if method == "GET":
                return {"data": localizations}
            self.patched.append((path, body["data"]["attributes"]["whatsNew"]))
            return {"data": {}}

        asc.api = fake_api

    def tearDown(self):
        asc.api = self.original_api
        asc.log = self.original_log

    def test_each_locale_gets_its_own_language(self):
        asc.set_whats_new("version-1", JA, EN)
        self.assertEqual(
            self.patched,
            [
                ("/v1/appStoreVersionLocalizations/loc-ja", JA),
                ("/v1/appStoreVersionLocalizations/loc-us", EN),
            ],
        )

    def test_without_english_the_english_page_is_left_alone(self):
        asc.set_whats_new("version-1", JA)
        self.assertEqual(self.patched, [("/v1/appStoreVersionLocalizations/loc-ja", JA)])


class ReadNotesTests(unittest.TestCase):
    def test_missing_path(self):
        self.assertIsNone(asc.read_notes(None))

    def test_strips_and_treats_blank_as_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "notes.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("\n\n")
            self.assertIsNone(asc.read_notes(path))
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("\n- One line.\n\n")
            self.assertEqual(asc.read_notes(path), "- One line.")


if __name__ == "__main__":
    unittest.main()
