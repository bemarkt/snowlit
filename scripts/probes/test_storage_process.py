import unittest
import uuid
import json
import tempfile
from pathlib import Path
from unittest.mock import patch

from storage_process import BUNDLE, DIGESTS, POINTS, Probe, read_progress, validate_active, validate_marker, verify_reopened


class StorageProcessEvidenceTests(unittest.TestCase):
    def test_order_comparison_keeps_all_commit_points_and_exactly_three_trials_each(self):
        self.assertEqual(next(iter(POINTS.items()))[0], 'dataset')
        self.assertEqual(POINTS['dataset'][0], 'oldClosed')
        self.assertEqual(set(POINTS['dataset']), {'candidateValidated', 'oldClosed', 'pointerCommitted', 'adopted'})
        self.assertEqual(set(POINTS['file']), {'temporaryWritten', 'filePromoted', 'beforeCommit', 'afterCommit'})
        probe = object.__new__(Probe)
        probe.results = []
        with patch.object(probe, 'operation', return_value={}) as operation, \
             patch.object(probe, 'save'), patch('storage_process.verify_reopened') as verify, patch('builtins.print'):
            probe.run()
        self.assertEqual(operation.call_count, 96)
        self.assertEqual(verify.call_count, 24)
        self.assertEqual(len(probe.results), 24)
        self.assertEqual({(r['kind'], r['point'], r['repetition']) for r in probe.results},
                         {(kind, point, n) for kind, points in POINTS.items() for point in points for n in range(1, 4)})

    def test_active_scene_requires_its_own_stage_and_exact_launch_identity(self):
        expected = dict(token="this-operation", mode="file-check", point="beforeCommit", pid=123)
        active = dict(expected, stage="active", details={})
        validate_active(active, **expected)
        for field, value in [("token", "old"), ("pid", 124), ("mode", "file-seed"),
                             ("point", "afterCommit"), ("stage", "completed")]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_active(dict(active, **{field: value}), **expected)
        with self.assertRaises(ValueError):
            validate_marker(active, **expected)

    def test_completed_storage_marker_waits_for_scene_readiness_before_termination(self):
        with tempfile.TemporaryDirectory() as directory:
            probe, token, marker, active, identity = self.ready_operation(directory)
            def activate(_delay):
                active.write_text(json.dumps(dict(marker, stage="active", details={})))
            def finish(process):
                self.assertTrue(active.exists())
                self.assertEqual(process, identity)
                return dict(observedGone=True)
            with patch("storage_process.uuid.uuid4", return_value=token), \
                 patch.object(probe, "command", return_value=f"{BUNDLE}: 123\n"), \
                 patch.object(probe, "identity", return_value=identity), \
                 patch.object(probe, "finish", side_effect=finish) as finished, \
                 patch("storage_process.time.sleep", side_effect=activate) as waited:
                result = probe.operation("trial", "file", "check", "beforeCommit")
            self.assertEqual(result, marker["details"])
            waited.assert_called_once()
            finished.assert_called_once()
            self.assertEqual(probe.operations[0]["activeScene"]["stage"], "active")

    def test_missing_scene_readiness_cannot_pass_with_a_valid_storage_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            probe, token, _marker, _active, identity = self.ready_operation(directory)
            with patch("storage_process.uuid.uuid4", return_value=token), \
                 patch.object(probe, "command", return_value=f"{BUNDLE}: 123\n"), \
                 patch.object(probe, "identity", return_value=identity), \
                 patch.object(probe, "finish") as finished, \
                 patch.object(probe, "interrupt", return_value=dict(observedGone=True)), \
                 patch("storage_process.subprocess.run") as sample, \
                 patch("storage_process.time.monotonic", side_effect=[0, 0, 0, 21, 22]):
                sample.return_value.returncode = 0
                with self.assertRaisesRegex(TimeoutError, "active scene"):
                    probe.operation("trial", "file", "check", "beforeCommit")
            finished.assert_not_called()
            self.assertEqual(probe.operations[0]["outcome"], "failed")

    @staticmethod
    def ready_operation(directory):
        probe = object.__new__(Probe)
        probe.simulator = "owned-simulator"
        probe.container = probe.evidence = Path(directory)
        probe.operations = []; probe.results = []
        token = uuid.uuid4()
        marker = dict(token=str(token).upper(), mode="file-check", point="beforeCommit", pid=123,
                      stage="completed", details=dict(expected="original"))
        folder = probe.container / "Library/Caches/SnowlitStorageProcessProbes/trial"
        folder.mkdir(parents=True)
        path = folder / (str(token).upper() + ".json")
        path.write_text(json.dumps(marker))
        identity = dict(pid=123, startedUTC="earlier", executable="Snowlit")
        return probe, token, marker, path.with_suffix(".active.json"), identity

    def test_progress_is_diagnostic_and_cannot_satisfy_a_completed_checkpoint(self):
        expected = dict(token="this-operation", mode="dataset-check", point="candidateValidated", pid=123)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "progress.json"
            self.assertIsNone(read_progress(path, **expected))
            marker = dict(expected, stage="progress", details={"phase": "opening-dataset-store"})
            path.write_text(json.dumps(marker))
            self.assertEqual(read_progress(path, **expected), "opening-dataset-store")
            with self.assertRaises(ValueError):
                validate_marker(marker, **expected)
            path.write_text(json.dumps(dict(marker, token="previous-launch")))
            with self.assertRaises(ValueError):
                read_progress(path, **expected)

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
