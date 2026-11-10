"""Check that measurement parsing retains identity and discards unrelated paths."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from process_samples import ProcessSamples, parse_native_snapshot, parse_processes


class ProcessSampleTests(unittest.TestCase):
    def test_identity_scan_selects_candidates_without_inventing_resource_metrics(self):
        rows = parse_processes("\n".join([
            "1 0 Tue Nov 10 00:00:00 2026 /sbin/launchd",
            "30 1 Tue Nov 10 00:00:01 2026 /runtime/com.apple.WebKit.WebContent",
            "40 1 Tue Nov 10 00:00:02 2026 /unrelated/other",
        ]), metrics=False)
        self.assertEqual([row["pid"] for row in rows], [1, 30])
        self.assertTrue(rows[1]["candidate"])
        self.assertTrue(all("cpuTime" not in row and "rssKiB" not in row for row in rows))

    def test_candidates_keep_ancestors_and_cpu_rss_without_executable_paths(self):
        output = """
  1 0 100 0:01.20 Tue Nov 10 00:00:00 2026 /sbin/launchd
 20 1 200 0:03.40 Tue Nov 10 00:01:00 2026 /runtime/launchd_sim
 30 20 8192 0:25.50 Tue Nov 10 00:02:00 2026 /runtime/com.apple.WebKit.WebContent
 40 20 4096 1:00.00 Tue Nov 10 00:03:00 2026 /Tests Folder/xctest
 50 1 1234 0:00.20 Tue Nov 10 00:04:00 2026 /unrelated/private-tool
"""
        rows = parse_processes(output)
        self.assertEqual([row["pid"] for row in rows], [1, 20, 30, 40])
        self.assertEqual([row["pid"] for row in rows if row["candidate"]], [30, 40])
        self.assertEqual(rows[2]["cpuTime"], "0:25.50")
        self.assertEqual(rows[2]["rssKiB"], 8192)
        self.assertEqual(rows[2]["startedUTC"], "2026-11-10T00:02:00+00:00")
        self.assertEqual(rows[3]["executable"], "xctest")
        self.assertTrue(all("/" not in row["executable"] for row in rows))

    def test_reused_pid_retains_different_start_identity(self):
        def row(second):
            return parse_processes(f"30 1 123 0:00.01 Tue Nov 10 00:00:{second} 2026 /xctest")[0]
        self.assertEqual(row("00")["pid"], row("10")["pid"])
        self.assertNotEqual(row("00")["startedUTC"], row("10")["startedUTC"])

    def test_empty_and_unrelated_snapshots_are_not_measurement_errors(self):
        self.assertEqual(parse_processes(""), [])
        self.assertEqual(parse_processes("0 0 100 0:01.20 Tue Nov 10 00:00:00 2026 kernel_task"), [])
        self.assertEqual(parse_processes("1 0 100 0:01.20 Tue Nov 10 00:00:00 2026 /sbin/launchd"), [])

    def test_truncated_or_duplicate_rows_fail_instead_of_looking_empty(self):
        with self.assertRaises(ValueError):
            parse_processes("30 1 123")
        row = "30 1 123 0:00.01 Tue Nov 10 00:00:00 2026 /xctest\n"
        with self.assertRaises(ValueError):
            parse_processes(row + row)


class NativeSampleTests(unittest.TestCase):
    def snapshot(self):
        return dict(timebaseNumerator=125, timebaseDenominator=3, exitedDuringDiscovery=2,
                    processes=[dict(pid=30, parentPID=20, startSeconds=1_794_268_800,
                                    startMicroseconds=123456, executable="com.apple.WebKit.WebContent",
                                    candidate=True, measurement="measured", rssBytes=8388608,
                                    userTicks=60000000, systemTicks=12000000)])

    def test_cpu_ticks_use_host_timebase_and_identity_keeps_microseconds(self):
        result = parse_native_snapshot(json.dumps(self.snapshot()))
        process = result["processes"][0]
        self.assertEqual(process["rssKiB"], 8192)
        self.assertEqual(process["cpuSeconds"], 3)
        self.assertTrue(process["startedUTC"].endswith(".123456+00:00"))
        self.assertEqual(result["exitedDuringDiscovery"], 2)

    def test_departed_candidates_and_ancestors_have_no_invented_metrics(self):
        for candidate, measurement in [(True, "exited-during-sample"),
                                       (True, "identity-changed-during-sample"),
                                       (False, "identity-only")]:
            snapshot = self.snapshot()
            row = snapshot["processes"][0]
            row.update(candidate=candidate, measurement=measurement)
            for key in ["rssBytes", "userTicks", "systemTicks"]:
                del row[key]
            result = parse_native_snapshot(json.dumps(snapshot))["processes"][0]
            self.assertEqual(result["measurement"], measurement)
            self.assertNotIn("rssKiB", result)
            self.assertNotIn("cpuSeconds", result)

    def test_invalid_or_duplicate_native_rows_are_rejected(self):
        for key, value in [("startMicroseconds", 1000000), ("rssBytes", -1),
                           ("measurement", "identity-only"), ("executable", "/private/Snowlit")]:
            snapshot = self.snapshot()
            snapshot["processes"][0][key] = value
            with self.assertRaises(ValueError):
                parse_native_snapshot(json.dumps(snapshot))
        snapshot = self.snapshot()
        snapshot["processes"] *= 2
        with self.assertRaises(ValueError):
            parse_native_snapshot(json.dumps(snapshot))
        snapshot = self.snapshot()
        snapshot["timebaseDenominator"] = 0
        with self.assertRaises(ValueError):
            parse_native_snapshot(json.dumps(snapshot))

    def test_timeout_and_native_failure_remain_errors_with_bounded_diagnostics(self):
        errors = [subprocess.TimeoutExpired(["sampler"], 2),
                  subprocess.CalledProcessError(1, ["sampler"], stderr=json.dumps(
                      dict(phase="metrics", pid=30, errorCode=1, private="must not be recorded")))]
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "samples.jsonl"
            samples = ProcessSamples(destination, Path(folder) / "sampler")
            with patch("process_samples.subprocess.run", side_effect=errors) as run:
                samples.sample("test")
                samples.sample("test")
            samples.close()
            self.assertEqual(samples.samples, 0)
            self.assertEqual(samples.errors, 2)
            self.assertEqual(run.call_args.kwargs["timeout"], 2)
            records = [json.loads(row) for row in destination.read_text().splitlines()]
            self.assertEqual(records[1]["errorType"], "TimeoutExpired")
            self.assertEqual(records[2]["queryPhase"], "metrics")
            self.assertEqual(records[2]["pid"], 30)
            self.assertNotIn("private", destination.read_text())

    @unittest.skipUnless(sys.platform == "darwin", "Real libproc requires macOS")
    def test_compiled_host_sampler_observes_its_own_live_identity_and_metrics(self):
        helper = os.environ["SNOWLIT_PROCESS_SAMPLER"]
        result = subprocess.run([helper, "--self"], capture_output=True, text=True, check=True, timeout=2)
        raw = json.loads(result.stdout)
        records = parse_native_snapshot(result.stdout)["processes"]
        process = next(row for row in records if row["pid"] == raw["samplerPID"])
        self.assertEqual(process["measurement"], "measured")
        self.assertGreater(process["rssKiB"], 0)
        self.assertGreater(process["cpuSeconds"], 0)
        self.assertLess(process["cpuSeconds"], 2)


if __name__ == "__main__":
    unittest.main()
