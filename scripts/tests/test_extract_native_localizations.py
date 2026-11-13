import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("extract_native_localizations", Path(__file__).resolve().parents[1] / "extract-native-localizations.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NativeLocalizationExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-localization-extract-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "Sources" / "Native"
        self.source.mkdir(parents=True)
        self.input = self.root / "compiler"
        self.input.mkdir()

    def write(self, filename, source, entries, version=1):
        source.write_text("Synthetic source\n")
        (self.input / ".source-snapshot.json").write_text(json.dumps({"version": 1, "source_files": MODULE.source_hashes(self.source, self.root)}))
        path = self.input / filename
        path.write_text(json.dumps({"version": version, "source": str(source), "tables": {"Localizable": entries}}))
        return path

    def entry(self, key, line=2):
        return {"key": key, "comment": "Translator context", "location": {"startingLine": line, "startingColumn": 8}}

    def test_merges_keys_but_retains_distinct_source_locations_and_excludes_dependencies(self):
        self.write("one.stringsdata", self.source / "One.swift", [self.entry("Done"), self.entry("Count: %lld")])
        self.write("two.stringsdata", self.source / "Two.swift", [self.entry("Done", 4), self.entry("")])
        self.write("external.stringsdata", self.root / "Dependency.swift", [self.entry("Not native")])
        result = MODULE.inventory(self.input, self.source, self.root)
        self.assertEqual(result["unique_table_keys"], 2)
        self.assertEqual(result["occurrences"], 3)
        self.assertEqual(len(next(x for x in result["keys"] if x["key"] == "Done")["occurrences"]), 2)
        self.assertEqual(len(result["source_files"]), 2)
        self.assertIn("not full localization coverage", result["scope"])

    def test_unknown_schema_missing_location_and_empty_inventory_fail(self):
        path = self.write("bad.stringsdata", self.source / "One.swift", [self.entry("Done")], version=2)
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            MODULE.inventory(self.input, self.source, self.root)
        payload = json.loads(path.read_text())
        payload["version"] = 1
        payload["tables"]["Localizable"][0]["location"] = {}
        path.write_text(json.dumps(payload))
        with self.assertRaisesRegex(ValueError, "Missing compiler source"):
            MODULE.inventory(self.input, self.source, self.root)
        path.unlink()
        with self.assertRaisesRegex(ValueError, "No native"):
            MODULE.inventory(self.input, self.source, self.root)

    def test_changed_sources_and_conflicting_duplicate_outputs_are_rejected(self):
        source = self.source / "One.swift"
        first = self.write("one.stringsdata", source, [self.entry("Done")])
        source.write_text("Changed after compiler snapshot\n")
        with self.assertRaisesRegex(ValueError, "changed after"):
            MODULE.inventory(self.input, self.source, self.root)
        source.write_text("Synthetic source\n")
        second = self.input / "duplicate.stringsdata"
        payload = json.loads(first.read_text())
        payload["tables"]["Localizable"] = [self.entry("Obsolete key")]
        second.write_text(json.dumps(payload))
        with self.assertRaisesRegex(ValueError, "Conflicting compiler outputs"):
            MODULE.inventory(self.input, self.source, self.root)
        second.write_bytes(first.read_bytes())
        self.assertEqual(MODULE.inventory(self.input, self.source, self.root)["unique_table_keys"], 1)

    def test_snapshot_refuses_existing_compiler_output(self):
        source = self.source / "One.swift"
        source.write_text("Synthetic source\n")
        MODULE.snapshot(self.input, self.source, self.root)
        with self.assertRaisesRegex(ValueError, "fresh empty"):
            MODULE.snapshot(self.input, self.source, self.root)

    def test_collection_is_bound_to_snapshot_and_filters_non_native_outputs(self):
        native = self.write("native.stringsdata", self.source / "One.swift", [self.entry("Done")])
        dependency = self.write("dependency.stringsdata", self.root / "Dependency.swift", [self.entry("Not native")])
        build = self.root / "isolated-build"
        build.mkdir()
        native.rename(build / native.name)
        dependency.rename(build / dependency.name)
        marker = build / ".native-localization-snapshot"
        digest = hashlib.sha256((self.input / ".source-snapshot.json").read_bytes()).hexdigest()
        marker.write_text(digest)
        MODULE.collect(build, self.input, self.source)
        result = MODULE.inventory(self.input, self.source, self.root)
        self.assertEqual([x["key"] for x in result["keys"]], ["Done"])
        marker.write_text("Different extraction run")
        with self.assertRaisesRegex(ValueError, "does not match"):
            MODULE.collect(build, self.input, self.source)


if __name__ == "__main__":
    unittest.main()
