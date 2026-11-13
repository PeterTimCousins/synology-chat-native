import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("copy_native_localizations", Path(__file__).resolve().parents[1] / "copy-native-localizations.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NativeLocalizationPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-localization-package-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / "build"
        self.source = self.build / MODULE.BUNDLE_NAME
        self.catalog_root = self.source / "Contents" / "Resources"
        self.catalog_root.mkdir(parents=True)
        self.resources = self.root / "Synthetic.app" / "Contents" / "Resources"
        self.resources.mkdir(parents=True)
        self.info = self.resources.parent / "Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "synthetic.localizations"}))

    def catalog(self, locale, values):
        folder = self.catalog_root / (locale + ".lproj")
        folder.mkdir()
        path = folder / "Localizable.strings"
        path.write_bytes(plistlib.dumps(values))
        return path

    def copy(self):
        return MODULE.copy_resources(self.build, self.resources, self.info)

    def test_copies_module_and_main_catalogs_byte_exact_and_preserves_identity(self):
        english = self.catalog("en", {"Settings": "Settings", "Done": "Done"})
        german = self.catalog("de", {"Settings": "Einstellungen", "Done": "Fertig"})
        self.assertEqual(set(self.copy()), {"en", "de"})
        for locale, source in [("en", english), ("de", german)]:
            self.assertEqual((self.resources / (locale + ".lproj") / source.name).read_bytes(), source.read_bytes())
            self.assertEqual((self.resources / MODULE.BUNDLE_NAME / "Contents" / "Resources" / (locale + ".lproj") / source.name).read_bytes(), source.read_bytes())
        info = plistlib.loads(self.info.read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "synthetic.localizations")
        self.assertEqual(info["CFBundleDevelopmentRegion"], "en")
        self.assertNotIn("CFBundleLocalizations", info)

    def test_missing_english_fails_before_modifying_package(self):
        self.catalog("de", {"Settings": "Einstellungen"})
        before = self.info.read_bytes()
        with self.assertRaisesRegex(ValueError, "English fallback"):
            self.copy()
        self.assertEqual(self.info.read_bytes(), before)
        self.assertEqual(list(self.resources.iterdir()), [])

    def test_incomplete_locale_is_not_advertised_or_copied(self):
        self.catalog("en", {"Settings": "Settings", "Done": "Done"})
        self.catalog("de", {"Settings": "Einstellungen"})
        before = self.info.read_bytes()
        with self.assertRaisesRegex(ValueError, "Incomplete catalog"):
            self.copy()
        self.assertEqual(self.info.read_bytes(), before)
        self.assertEqual(list(self.resources.iterdir()), [])

    def test_missing_bundle_and_existing_destination_fail_without_overwrite(self):
        with self.assertRaisesRegex(ValueError, "Missing native resource"):
            MODULE.copy_resources(self.root / "absent", self.resources, self.info)
        self.catalog("en", {"Settings": "Settings"})
        existing = self.resources / "en.lproj"
        existing.mkdir()
        marker = existing / "untouched.txt"
        marker.write_text("Existing package content")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.copy()
        self.assertEqual(marker.read_text(), "Existing package content")

    def test_nested_development_symlink_is_rejected(self):
        self.catalog("en", {"Settings": "Settings"})
        outside = self.root / "outside.txt"
        outside.write_text("Not a package resource")
        (self.catalog_root / "development-link").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "development symlink"):
            self.copy()
        self.assertEqual(list(self.resources.iterdir()), [])

    def plural(self, locale, **changes):
        rule = {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                "NSStringFormatValueTypeKey": "lld", "one": "%lld reply", "other": "%lld replies"}
        rule.update(changes)
        path = self.catalog_root / (locale + ".lproj") / "Localizable.stringsdict"
        path.write_bytes(plistlib.dumps({"%lld replies": {"NSStringLocalizedFormatKey": "%#@count@", "count": rule}}))
        return path

    def test_copies_valid_plural_catalogs_in_both_resource_locations(self):
        self.catalog("en", {"Settings": "Settings"})
        self.catalog("de", {"Settings": "Einstellungen"})
        english = self.plural("en")
        german = self.plural("de", one="%lld Antwort", other="%lld Antworten")
        self.copy()
        for locale, source in [("en", english), ("de", german)]:
            self.assertEqual((self.resources / (locale + ".lproj") / source.name).read_bytes(), source.read_bytes())
            self.assertEqual((self.resources / MODULE.BUNDLE_NAME / "Contents" / "Resources" / (locale + ".lproj") / source.name).read_bytes(), source.read_bytes())

    def test_translation_cannot_remove_plural_rules_by_using_a_scalar(self):
        self.catalog("en", {"Settings": "Settings"})
        self.plural("en")
        self.catalog("de", {"Settings": "Einstellungen", "%lld replies": "%lld Antworten"})
        with self.assertRaisesRegex(ValueError, "Scalar catalog keys|Plural catalog keys"):
            self.copy()
        self.assertEqual(list(self.resources.iterdir()), [])

    def test_bad_plural_types_branches_and_missing_other_fail_before_copy(self):
        self.catalog("en", {"Settings": "Settings"})
        self.catalog("de", {"Settings": "Einstellungen"})
        self.plural("en")
        for changes in [{"NSStringFormatValueTypeKey": "d"}, {"one": "%@ Antwort"}, {"other": "Antworten"}, {"few": "%lld %@"}]:
            with self.subTest(changes=changes):
                self.plural("de", **changes)
                with self.assertRaises(ValueError):
                    self.copy()
                self.assertEqual(list(self.resources.iterdir()), [])
        path = self.plural("de")
        values = plistlib.loads(path.read_bytes())
        del values["%lld replies"]["count"]["other"]
        path.write_bytes(plistlib.dumps(values))
        with self.assertRaisesRegex(ValueError, "Missing other"):
            self.copy()
        self.assertEqual(list(self.resources.iterdir()), [])

    def test_scalar_argument_type_mismatch_fails_before_copy(self):
        self.catalog("en", {"%lld results": "%lld results"})
        self.catalog("de", {"%lld results": "%@ Ergebnisse"})
        with self.assertRaises(ValueError):
            self.copy()
        self.assertEqual(list(self.resources.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
