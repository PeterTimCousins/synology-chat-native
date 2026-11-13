import importlib.util
import json
from pathlib import Path
import subprocess
import unittest


SPEC = importlib.util.spec_from_file_location("native_localization_formats", Path(__file__).resolve().parents[1] / "native_localization_formats.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NativeScalarLocalizationFormatsTests(unittest.TestCase):
    def validate(self, english, translated):
        MODULE.validate_scalar_catalog({"synthetic": english}, {"synthetic": translated})

    def reject(self, english, translated, reason=None):
        with self.assertRaisesRegex(MODULE.FormatValidationError, reason or "."):
            self.validate(english, translated)

    def test_positional_reordering_and_repetition_preserve_identity(self):
        self.validate("%@ has %lld files", "%2$lld Dateien für %1$@ (%1$@)")
        self.validate("%2$lld files for %1$@ / %1$@", "%1$@ has %2$lld files")

    def test_literal_percentages_remain_prose(self):
        for value in ["100%", "<1%", "Pinch to zoom. Switch between Fit and 100%.", "100% complete", "50% of files"]:
            with self.subTest(value=value):
                self.assertEqual(MODULE.scalar_format_contract(value), {})
                self.validate(value, value)
        self.validate("100%", "100 %")

    def test_escaped_percent_does_not_consume_argument(self):
        self.validate("%lld%% of %@", "%2$@ : %1$lld%%")
        self.assertEqual(MODULE.scalar_format_contract("%%"), {})

    def test_dropped_added_or_changed_argument_is_rejected(self):
        self.reject("%@", "Plain")
        self.reject("Plain", "%@")
        self.reject("%@ %lld", "%1$@")
        self.reject("%@", "%@ %@")

    def test_length_signedness_and_pointer_type_are_preserved(self):
        for original, localized in [("%lld", "%d"), ("%ld", "%lld"), ("%hu", "%u"), ("%d", "%u"), ("%zd", "%td"), ("%@", "%s"), ("%p", "%@"), ("%s", "%S"), ("%c", "%C"), ("%f", "%Lf")]:
            with self.subTest(original=original, localized=localized):
                self.reject(original, localized, "types differ")

    def test_same_numeric_type_allows_conversion_style_change(self):
        for original, localized in [("%d", "%i"), ("%u", "%x"), ("%f", "%e"), ("%f", "%lf"), ("%qd", "%lld"), ("%D", "%ld")]:
            self.validate(original, localized)

    def test_width_precision_and_flags_do_not_change_arguments(self):
        self.validate("%@ %lld %.2f", "%3$+08.3f %2$#020lld %1$@")

    def test_mixed_argument_modes_are_rejected(self):
        self.reject("%@ %lld", "%1$@ %lld", "Mixed")
        self.reject("%@ %lld", "%@ %2$lld", "Mixed")

    def test_invalid_or_gapped_positions_are_rejected(self):
        for value in ["%0$@", "%2$@", "%1$@ %3$lld", "%1$Q", "%2147483647$@", "%99999999999999999999999$@"]:
            with self.subTest(value=value):
                self.reject("%@", value)

    def test_repeated_position_cannot_change_type(self):
        self.reject("%@", "%1$@ %1$lld", "Repeated")

    def test_write_directive_is_always_forbidden(self):
        for value in ["%n", "%ln", "%1$n", "%@ %hhn"]:
            self.reject("Plain", value, "Forbidden")

    def test_star_width_and_precision_are_rejected(self):
        for value in ["%*d", "%.*f", "%1$*2$d", "%1$.*2$f", "%08.*f"]:
            self.reject("Plain", value, "Star")

    def test_recognized_format_rejects_other_malformed_percent(self):
        for value in ["%@ %Q", "%@ %", "%@ 100% complete", "%@ %.Q", "%@ %llq"]:
            self.reject("%@", value, "Malformed")

    def test_bad_length_conversion_combinations_are_rejected(self):
        for value in ["%l@", "%Ls", "%llf", "%hp", "%lC"]:
            self.reject("Plain", value, "Invalid")

    def test_catalog_structure_is_validated(self):
        for english, translated in [({"key": "A"}, {}), ({"key": "A"}, {"key": "A", "extra": "B"}), ({"key": 4}, {"key": "A"}), ({"key": "A"}, {"key": []}), ({1: "A"}, {1: "B"}), ({"": "A"}, {"": "B"}), ([], {})]:
            with self.assertRaises(MODULE.FormatValidationError):
                MODULE.validate_scalar_catalog(english, translated)

    def test_current_english_catalog_is_valid_without_evaluation(self):
        catalog = Path(__file__).resolve().parents[2] / "Sources/SynologyChatNative/Resources/en.lproj/Localizable.strings"
        values = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(catalog)]))
        self.assertGreater(len(values), 1200)
        MODULE.validate_scalar_catalog(values, values)


if __name__ == "__main__":
    unittest.main()
