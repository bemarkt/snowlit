"""Missing execution evidence must never become an accepted probe run."""

import json
from datetime import datetime, timezone
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

    def test_reader_ui_requires_the_exact_completed_xctest(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            with self.assertRaises(ValueError):
                verify(root, "reader-ui")
            path = root / "webkit-tests.log"
            method = "testSystemCurlCommitsCompletedGesturesAndKeepsPageAfterCancellation"
            path.write_text(f"Test Case '-[SnowlitUITests.ReaderInteractionUITests {method}]' passed\n"
                            "Test Suite 'ReaderInteractionUITests' passed")
            self.assertEqual(verify(root, "reader-ui")["reportedTests"], 1)
            path.write_text(path.read_text().replace("' passed", "' failed", 1))
            with self.assertRaises(ValueError):
                verify(root, "reader-ui")

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
            self.recovery_observations(root)
            self.assertEqual(verify(root, "recovery")["result"], "passed")

    def recovery_observations(self, root):
        log = ["Suite WebKitRecoveryTests passed", "Test run with 1 test in 1 suite passed"]
        samples = [dict(kind="metadata", format=3)]
        for fault_index, fault in enumerate(["spin", "never"]):
            for repetition in range(1, 4):
                baseline = 100 * (fault_index * 3 + repetition)
                for stage, delta in [("baseline", 0), ("execution-requested", 1), ("fault-entered", 1.1),
                                     ("waiter-ended", 1.3), ("closed", 2.4),
                                     ("replacement-ready", 3), ("observation-ended", 5)]:
                    log.append(f"RecoveryEvent epochSeconds={baseline + delta} stage={stage} "
                               f"fault={fault} repetition={repetition} hostPID=50")
                for index in range(1, 20):
                    samples.append(dict(kind="sample", durationSeconds=0.01,
                        observedUTC=datetime.fromtimestamp(baseline + index / 4, timezone.utc).isoformat(),
                        processes=[dict(pid=50, executable="Snowlit", measurement="measured"),
                                   dict(pid=60, executable="com.apple.WebKit.WebContent", measurement="measured")]))
        (root / "webkit-tests.log").write_text("\n".join(log))
        (root / "process-samples.jsonl").write_text("\n".join(json.dumps(row) for row in samples))
        status_path = root / "webkit-tests.status.json"
        status = json.loads(status_path.read_text())
        status["processSamples"] = len(samples) - 1
        status_path.write_text(json.dumps(status))

    def test_missing_fault_entry_empty_processes_and_observation_gaps_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            for damage in ["missing-entry", "empty", "gap", "error"]:
                self.recovery_observations(root)
                if damage == "missing-entry":
                    path = root / "webkit-tests.log"
                    path.write_text(path.read_text().replace("stage=fault-entered", "stage=unproven"))
                else:
                    path = root / "process-samples.jsonl"
                    records = [json.loads(row) for row in path.read_text().splitlines()]
                    if damage == "error":
                        records.append(dict(kind="samplingError"))
                    else:
                        for row in records[1:]:
                            stamp = datetime.fromisoformat(row["observedUTC"]).timestamp()
                            if damage == "empty" or 101.1 < stamp < 102.4:
                                row["processes"] = []
                    path.write_text("\n".join(json.dumps(row) for row in records))
                with self.assertRaises(ValueError, msg=damage):
                    verify(root, "recovery")

    def test_zero_webcontent_after_close_is_observed_data_but_missing_samples_are_not(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            self.recovery_observations(root)
            path = root / "process-samples.jsonl"
            records = [json.loads(row) for row in path.read_text().splitlines()]
            for row in records[1:]:
                stamp = datetime.fromisoformat(row["observedUTC"]).timestamp()
                if 102.4 < stamp < 103:
                    row["processes"] = [p for p in row["processes"] if p["pid"] == 50]
            path.write_text("\n".join(json.dumps(row) for row in records))
            result = verify(root, "recovery")
            self.assertEqual(len(result["samplingCoverage"]["windows"]), 24)
            for row in records[1:]:
                stamp = datetime.fromisoformat(row["observedUTC"]).timestamp()
                if 102.4 < stamp < 104.5:
                    row["processes"] = []
            path.write_text("\n".join(json.dumps(row) for row in records))
            with self.assertRaises(ValueError):
                verify(root, "recovery")


if __name__ == "__main__":
    unittest.main()
