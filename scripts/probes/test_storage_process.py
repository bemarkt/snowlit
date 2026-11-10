import unittest
import uuid
from unittest.mock import patch

from storage_process import DIGESTS, Probe, validate_marker, verify_reopened


class StorageProcessEvidenceTests(unittest.TestCase):
    def test_completed_operation_uses_simulator_lifecycle_and_observes_process_exit(self):
        probe = object.__new__(Probe)
        probe.simulator = "owned-simulator"
        original = dict(pid=123, startedUTC="earlier", executable="Snowlit")
        with patch.object(probe, "identity", side_effect=[original, original, None]), \
             patch.object(probe, "command") as command, patch("storage_process.os.kill") as kill:
            result = probe.finish(original)
        command.assert_called_once_with("terminate", "owned-simulator", "io.github.bemarkt.snowlit")
        kill.assert_not_called()
        self.assertEqual(result["method"], "simctl-terminate")
        self.assertTrue(result["observedGone"])

    def test_checkpoint_still_requires_sigkill_of_the_exact_owned_identity(self):
        probe = object.__new__(Probe)
        original = dict(pid=123, startedUTC="earlier", executable="Snowlit")
        with patch.object(probe, "identity", side_effect=[original, None]), \
             patch("storage_process.os.kill") as kill, patch.object(probe, "command") as command, \
             patch("storage_process.signal.SIGKILL", 9, create=True):
            result = probe.interrupt(original)
        self.assertEqual(kill.call_args.args[0], original["pid"])
        self.assertEqual(kill.call_args.args[1], 9)
        self.assertEqual(result["signal"], "SIGKILL")
        command.assert_not_called()
        self.assertTrue(result["observedGone"])

    def test_completed_operation_never_terminates_a_changed_identity(self):
        probe = object.__new__(Probe)
        original = dict(pid=123, startedUTC="earlier", executable="Snowlit")
        with patch.object(probe, "identity", return_value=dict(original, startedUTC="later")), \
             patch.object(probe, "command") as command:
            with self.assertRaises(ValueError):
                probe.finish(original)
        command.assert_not_called()

    def test_changed_process_identity_never_receives_a_signal(self):
        probe = object.__new__(Probe)
        original = dict(pid=123, startedUTC="earlier", executable="Snowlit")
        reused = dict(original, startedUTC="later")
        with patch.object(probe, "identity", return_value=reused), patch("storage_process.os.kill") as kill:
            with self.assertRaises(ValueError):
                probe.interrupt(original)
            kill.assert_not_called()

    def test_rejects_stale_launch_wrong_process_and_unreached_commit(self):
        expected = dict(token="this-operation", mode="file-write", point="beforeCommit", pid=123)
        marker = dict(expected, stage="checkpoint", details={"reached": "beforeCommit"})
        validate_marker(marker, **expected)
        for key, value in [("token", "old-operation"), ("pid", 124), ("mode", "file-check"),
                           ("point", "afterCommit"), ("stage", "completed"),
                           ("details", {"reached": "afterCommit"})]:
            with self.subTest(field=key), self.assertRaises(ValueError):
                validate_marker(dict(marker, **{key: value}), **expected)

    def test_requires_exact_content_and_idempotent_cleanup_after_second_reopen(self):
        first = dict(expected="original", contentSHA256=DIGESTS["original"],
                     removedOrphans="1", secondRecoveryRemoved="0")
        second = dict(first, removedOrphans="0")
        verify_reopened("file", "beforeCommit", first, second)
        for corrupted in [dict(second, contentSHA256=DIGESTS["replacement"]),
                          dict(second, removedOrphans="1"), dict(second, secondRecoveryRemoved="1")]:
            with self.assertRaises(ValueError):
                verify_reopened("file", "beforeCommit", first, corrupted)
        with self.assertRaises(ValueError):
            verify_reopened("file", "afterCommit", first, second)

    def test_dataset_commit_requires_stable_new_pointer_and_readable_original(self):
        first = dict(expected="replacement", contentSHA256=DIGESTS["replacement"],
                     originalContentSHA256=DIGESTS["original"],
                     originalDataset=str(uuid.uuid4()), activeDataset=str(uuid.uuid4()))
        verify_reopened("dataset", "pointerCommitted", first, dict(first))
        for corrupted in [dict(first, activeDataset=str(uuid.uuid4())),
                          dict(first, originalContentSHA256=DIGESTS["replacement"])]:
            with self.assertRaises(ValueError):
                verify_reopened("dataset", "pointerCommitted", first, corrupted)
        same = dict(first, activeDataset=first["originalDataset"])
        with self.assertRaises(ValueError):
            verify_reopened("dataset", "pointerCommitted", same, same)


if __name__ == "__main__":
    unittest.main()
