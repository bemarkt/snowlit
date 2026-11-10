import copy
from pathlib import Path
import tempfile
import unittest
from termination_control import TerminationControl


class TerminationControlTests(unittest.TestCase):
    def snapshot(self):
        return {'processes': [
            dict(pid=10, parentPID=1, executable='launchd_sim', startedUTC='a', measurement='identity-only'),
            dict(pid=20, parentPID=10, executable='Snowlit', startedUTC='b', measurement='measured'),
            dict(pid=30, parentPID=10, executable='com.apple.WebKit.WebContent', startedUTC='c', measurement='measured'),
            dict(pid=40, parentPID=99, executable='com.apple.WebKit.WebContent', startedUTC='d', measurement='measured')]}

    def run_request(self, snapshot, current=None):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory)/'test.log'
            log.write_text('TerminationRequest token=11111111-1111-1111-1111-111111111111 hostPID=20\n')
            calls = []
            control = TerminationControl(log, kill=lambda pid: calls.append(pid))
            control.poll(snapshot, lambda: current or snapshot)
            control.poll(snapshot, lambda: current or snapshot)
            return calls, control

    def test_only_unique_same_simulator_child_is_signalled_once(self):
        calls, control = self.run_request(self.snapshot())
        self.assertEqual(calls, [30])
        self.assertEqual(control.errors, 0)
        self.assertEqual(len(control.results), 1)

    def test_absent_host_foreign_parent_multiple_targets_or_pid_reuse_never_signal(self):
        variants = []
        missing = self.snapshot(); missing['processes'].pop(1); variants.append((missing, None))
        foreign = self.snapshot(); foreign['processes'][0]['executable'] = 'launchd'; variants.append((foreign, None))
        ambiguous = self.snapshot(); ambiguous['processes'][3]['parentPID'] = 10; variants.append((ambiguous, None))
        old = self.snapshot(); reused = copy.deepcopy(old); reused['processes'][2]['startedUTC'] = 'new'; variants.append((old, reused))
        exited = self.snapshot(); exited['processes'][2]['measurement'] = 'exited-during-sample'; variants.append((exited, None))
        for before, after in variants:
            calls, control = self.run_request(before, after)
            self.assertEqual(calls, [])
            self.assertEqual(control.errors, 1)


if __name__ == '__main__':
    unittest.main()
