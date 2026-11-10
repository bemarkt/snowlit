"""Missing execution evidence must never become an accepted probe run."""

import json
from pathlib import Path
import tempfile
import unittest

from verify_execution import verify


class VerifyExecutionTests(unittest.TestCase):
    def fixture(self, root):
        (root / "RuntimeTests.xcresult").mkdir()
        (root / "RuntimeTests.xcresult/Info.plist").write_text("test-only placeholder")
        (root / "webkit-tests.status.json").write_text(json.dumps({
            "exitCode": 0, "processExitCode": 0, "timedOut": False, "interrupted": False,
            "processSamples": 4, "processSamplingErrors": 0,
        }))
        (root / "webkit-tests.log").write_text("\n".join([
            "Suite WebKitRuntimeProbeTests passed", "Suite ReaderProbeTests passed",
            "Test run with 14 tests in 2 suites passed",
        ]))

    def test_missing_bundle_or_execution_log_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaises(FileNotFoundError):
                verify(root, "integration")
            self.fixture(root)
            (root / "RuntimeTests.xcresult/Info.plist").unlink()
            with self.assertRaises(ValueError):
                verify(root, "integration")

    def test_zero_tests_missing_suite_or_command_failure_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            for log in ["Test run with 0 tests in 0 suites passed",
                        "Suite ReaderProbeTests passed\nTest run with 5 tests in 1 suite passed"]:
                (root / "webkit-tests.log").write_text(log)
                with self.assertRaises(ValueError):
                    verify(root, "integration")
            status = root / "webkit-tests.status.json"
            recorded = json.loads(status.read_text())
            recorded["processExitCode"] = 65
            status.write_text(json.dumps(recorded))
            with self.assertRaises(ValueError):
                verify(root, "integration")

    def test_complete_suites_are_required_and_recovery_also_needs_samples(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            self.assertEqual(verify(root, "integration")["reportedTests"], 14)
            (root / "webkit-tests.log").write_text(
                "Suite WebKitRecoveryTests passed\nTest run with 1 test in 1 suite passed")
            with self.assertRaises(ValueError):
                verify(root, "recovery")
            (root / "process-samples.jsonl").write_text("test-only placeholder\n")
            self.assertEqual(verify(root, "recovery")["result"], "passed")


if __name__ == "__main__":
    unittest.main()
