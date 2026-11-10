"""Exercise actual child output, exit codes and the supervisor's process deadline."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(os.name == 'posix', 'The Apple supervisor owns POSIX process groups')
class SupervisionTests(unittest.TestCase):
    def command(self, folder, body, timeout=5):
        return [sys.executable, str(Path(__file__).with_name('supervise.py')),
                '--timeout', str(timeout), '--log', str(folder / 'command.log'),
                '--', sys.executable, '-c', body]

    def test_streams_output_while_the_child_is_still_running(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            release = folder / 'release'
            body = ("from pathlib import Path; import time\n"
                    "print('child-ready', flush=True)\n"
                    f"release=Path({str(release)!r})\n"
                    "while not release.exists(): time.sleep(0.02)\n"
                    "print('child-finished', flush=True)\n")
            process = subprocess.Popen(self.command(folder, body, timeout=10),
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.assertTrue(select.select([process.stdout], [], [], 5)[0])
                first = process.stdout.readline()
                self.assertEqual(first, b'child-ready\n')
                self.assertIsNone(process.poll())
                release.touch()
                rest, errors = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, errors)
                # The final JSON includes the command source, which itself
                # contains the marker literals. Compare actual output lines.
                lines = rest.splitlines()
                self.assertEqual(len(lines), 2)
                self.assertEqual(lines[0], b'child-finished')
                status = json.loads(lines[1])
                self.assertEqual(status['exitCode'], 0)
                self.assertFalse(status['timedOut'])
                self.assertEqual((folder / 'command.log').read_bytes(),
                                 b'child-ready\nchild-finished\n')
            finally:
                release.touch()
                if process.poll() is None:
                    process.communicate(timeout=12)

    def test_nonzero_exit_after_multiple_polls_is_not_reported_as_timeout(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            result = subprocess.run(self.command(folder,
                "import time,sys; time.sleep(0.6); print('expected-failure', flush=True); sys.exit(7)"),
                capture_output=True, timeout=10)
            status = json.loads((folder / 'command.status.json').read_text())
            self.assertEqual(result.returncode, 7)
            self.assertEqual(status['processExitCode'], 7)
            self.assertFalse(status['timedOut'])
            self.assertIn(b'expected-failure\n', result.stdout)

    def test_deadline_ends_the_owned_child_and_preserves_its_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            result = subprocess.run(self.command(folder,
                "import time; print('entered-wait', flush=True); time.sleep(30)", timeout=0.7),
                capture_output=True, timeout=10)
            status = json.loads((folder / 'command.status.json').read_text())
            self.assertEqual(result.returncode, 124)
            self.assertTrue(status['timedOut'])
            self.assertNotEqual(status['processExitCode'], 0)
            self.assertEqual((folder / 'command.log').read_bytes(), b'entered-wait\n')
            self.assertIn(b'entered-wait\n', result.stdout)
