import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

WRAPPER = Path(__file__).with_name("run-native-own-edit-probe.py")


class ProbeOutputBoundaryTests(unittest.TestCase):
    def test_runtime_credentials_are_suppressed_before_summary_or_output(self):
        with tempfile.TemporaryDirectory(prefix="native-edit-output-") as temporary:
            directory = Path(temporary)
            binary = directory / "synthetic-child"
            binary.write_text('#!/usr/bin/env python3\nimport pathlib,sys\n'
                              'print("Runtime URL https://synthetic.invalid/?_sid=FAKE_SECRET_SESSION&SynoToken=FAKE_SECRET_TOKEN",file=sys.stderr)\n'
                              'pathlib.Path(sys.argv[2]).write_text("{}")\n'
                              'print("Verified current-model edit and zero-attempt conflict refusal fixture")\n')
            binary.chmod(0o700)
            receipt, summary = directory / "receipt.json", directory / "summary.json"
            result = subprocess.run([sys.executable, str(WRAPPER), str(binary), str(receipt), str(summary)],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0)
            retained = result.stdout + result.stderr + summary.read_text()
            self.assertNotIn("FAKE_SECRET_SESSION", retained)
            self.assertNotIn("FAKE_SECRET_TOKEN", retained)
            report = json.loads(summary.read_text())
            self.assertEqual(report["probe_statuses"], ["verified"])
            self.assertEqual(report["suppressed_runtime_lines"], 1)
            self.assertFalse(report["raw_runtime_output_retained"])
            self.assertEqual(summary.stat().st_mode & 0o777, 0o600)

    def test_existing_receipt_or_summary_prevents_child_and_preserves_record(self):
        for existing in ("receipt", "summary"):
            with self.subTest(existing=existing), tempfile.TemporaryDirectory(prefix="native-edit-no-retry-") as temporary:
                directory = Path(temporary)
                binary = directory / "synthetic-child"
                marker = directory / "executed"
                binary.write_text('#!/usr/bin/env python3\nimport pathlib\npathlib.Path(' + repr(str(marker)) + ').write_text("unsafe")\n')
                binary.chmod(0o700)
                receipt, summary = directory / "receipt.json", directory / "summary.json"
                protected = receipt if existing == "receipt" else summary
                original = '{"state":"dispatching_do_not_repeat"}\n'
                protected.write_text(original)
                result = subprocess.run([sys.executable, str(WRAPPER), str(binary), str(receipt), str(summary)],
                                        capture_output=True, text=True, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(marker.exists())
                self.assertEqual(protected.read_text(), original)


if __name__ == "__main__":
    unittest.main()
