#!/usr/bin/env python3
"""Exercise fail-closed release decisions using synthetic evidence only."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_status", Path(__file__).with_name("release-status.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ReleaseStatusTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        proof = self.root / "synthetic-proof.txt"
        proof.write_text("Synthetic retained evidence")
        self.current = {"head": "synthetic-head", "head_tree": "synthetic-tree", "branch": "synthetic-branch",
                        "index_sha256": "synthetic-index", "working_input_sha256": "synthetic-sha", "inputs": {"file": "sha"}}
        self.document = {**self.current, "outcomes": [
            {"id": row_id, "canonical_status": "accepted", "scores": [1] * 10, "reachable": "yes", "blockers": [],
             "evidence": [{"path": "synthetic-proof.txt", "sha256": gate.sha(proof)}]}
            for row_id in sorted(gate.REQUIRED)], "cumulative_checks": {key: "closed" for key in gate.CHECKS}}

    def verdict(self, document=None, current=None):
        return gate.check(document or self.document, current or self.current, root=self.root)["verdict"]

    def testFullyPinnedSyntheticAcceptanceCanPass(self):
        self.assertEqual(self.verdict(), "GO")

    def testFreshEvidenceCannotSubstituteForCanonicalAcceptance(self):
        self.document["outcomes"][0]["canonical_status"] = "implemented"
        self.assertEqual(self.verdict(), "NO-GO")

    def testSourceOrIndexDriftInvalidatesAssessment(self):
        for key in ("working_input_sha256", "index_sha256", "head", "inputs"):
            with self.subTest(key=key):
                current = copy.deepcopy(self.current)
                current[key] = "changed"
                self.assertEqual(self.verdict(current=current), "NO-GO")

    def testOmittedOrDuplicatedRequirementCannotPass(self):
        original = copy.deepcopy(self.document)
        self.document["outcomes"].pop()
        self.assertEqual(self.verdict(), "NO-GO")
        self.document = original
        self.document["outcomes"][-1] = copy.deepcopy(self.document["outcomes"][0])
        self.assertEqual(self.verdict(), "NO-GO")

    def testPartialMalformedAndUnknownDimensionsCannotPass(self):
        for value in (0, 0.5, True, "complete", 2):
            with self.subTest(value=value):
                self.document["outcomes"][0]["scores"][0] = value
                self.assertEqual(self.verdict(), "NO-GO")
        self.document["outcomes"][0]["scores"] = [None] * 10
        self.assertEqual(self.verdict(), "NO-GO")

    def testLostOrChangedRetainedEvidenceCannotPass(self):
        (self.root / "synthetic-proof.txt").write_text("Changed")
        self.assertEqual(self.verdict(), "NO-GO")
        (self.root / "synthetic-proof.txt").unlink()
        self.assertEqual(self.verdict(), "NO-GO")

    def testBlockersAndCumulativeChecksRemainBinding(self):
        self.document["outcomes"][0]["blockers"] = [{"class": "external_evidence"}]
        self.assertEqual(self.verdict(), "NO-GO")
        self.document["outcomes"][0]["blockers"] = []
        self.document["cumulative_checks"]["security"] = "open"
        self.assertEqual(self.verdict(), "NO-GO")

    def testInapplicableDimensionsNeedSpecificRecordedReasons(self):
        self.document["outcomes"][0]["scores"][8] = None
        self.assertEqual(self.verdict(), "NO-GO")
        self.document["outcomes"][0]["not_applicable"] = {"8": "Synthetic fixture has no external service"}
        self.assertEqual(self.verdict(), "GO")


if __name__ == "__main__":
    unittest.main()
