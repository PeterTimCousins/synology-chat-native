import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("gate", Path(__file__).with_name("parity-status.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ParityGateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "source").write_text("current")
        digest = hashlib.sha256(b"current").hexdigest()
        self.document = {"rows": [{"id": key, "parity_acceptance": {
            "status": "accepted", "review": "Explicit whole-workflow comparison",
            "evidence": [{"path": "source", "sha256": digest}], "runtime_inputs": {"source": digest}}}
            for key in sorted(gate.REQUIRED)]}

    def result(self):
        return gate.check(self.document, self.root)["verdict"]

    def test_explicit_fresh_acceptance(self):
        self.assertEqual(self.result(), "GO")

    def test_missing_or_duplicate_feature_fails(self):
        self.document["rows"][-1] = self.document["rows"][0]
        self.assertEqual(self.result(), "NO-GO")

    def test_core_tested_is_not_full_parity(self):
        self.document["rows"][0] = {"id": "F001", "native_status": "core-tested"}
        self.assertEqual(self.result(), "NO-GO")

    def test_changed_input_or_proof_fails(self):
        (self.root / "source").write_text("changed")
        self.assertEqual(self.result(), "NO-GO")

    def test_missing_review_or_proof_fails(self):
        self.document["rows"][0]["parity_acceptance"]["evidence"] = []
        self.assertEqual(self.result(), "NO-GO")


if __name__ == "__main__":
    unittest.main()
