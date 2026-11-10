"""Check that measurement parsing retains identity and discards unrelated paths."""

import unittest

from process_samples import parse_processes


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


if __name__ == "__main__":
    unittest.main()
