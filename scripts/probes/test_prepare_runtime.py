"""Exercise runtime selection with fake tools; this is not simulator validation."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


BASH = os.environ.get("SNOWLIT_BASH", "/bin/bash")
SCRIPT = Path(__file__).resolve().parents[1] / "prepare_runtime.sh"


@unittest.skipUnless(Path(BASH).is_file(), "A Bash executable is required")
class RuntimePreparationTests(unittest.TestCase):
    def run_fixture(self, scenario, initial, installed):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / "evidence"
            state = root / "state.json"
            state.write_text(json.dumps(initial))
            (root / "installed.json").write_text(json.dumps(installed))
            scripts = {
                "python3": "#!/bin/bash\nexec " + shlex.quote(Path(sys.executable).as_posix()) + ' "$@"\n',
                "xcrun": '#!/bin/bash\ncat "$SNOWLIT_RUNTIME_FIXTURE/state.json"\n',
                "xcodebuild": '''#!/bin/bash
printf '%s\\n' "$*" >> "$SNOWLIT_RUNTIME_FIXTURE/calls.txt"
if [ "$SNOWLIT_RUNTIME_SCENARIO" = fail ]; then exit 70; fi
if [ "$SNOWLIT_RUNTIME_SCENARIO" = fallback ] && [ "$4" = 26.0 ]; then exit 70; fi
cp "$SNOWLIT_RUNTIME_FIXTURE/installed.json" "$SNOWLIT_RUNTIME_FIXTURE/state.json"
''',
            }
            for name, source in scripts.items():
                executable = root / name
                executable.write_text(source, encoding="utf-8", newline="\n")
                executable.chmod(0o700)
            environment = os.environ.copy()
            environment.update(SNOWLIT_RUNTIME_FIXTURE=root.as_posix(), SNOWLIT_RUNTIME_SCENARIO=scenario)
            # Bash resolves these temporary fake tools before real Xcode tools.
            shell_root = root.as_posix()
            if sys.platform == "win32":
                shell_root = "/" + shell_root[0].lower() + shell_root[2:]
            command = 'export PATH=' + shlex.quote(shell_root) + ':"$PATH"; exec bash ' + shlex.quote(SCRIPT.as_posix())
            command += ' 26.0 ' + shlex.quote(evidence.as_posix())
            result = subprocess.run([BASH, "-c", command], env=environment, capture_output=True, text=True, timeout=20)
            files = {path.name: path.read_text() for path in evidence.iterdir()}
            calls = (root / "calls.txt").read_text().splitlines() if (root / "calls.txt").exists() else []
            return result, files, calls

    @staticmethod
    def runtime(version="26.0", build="23A343"):
        return dict(runtimes=[dict(identifier="com.apple.CoreSimulator.SimRuntime.iOS-26-0",
                                   isAvailable=True, version=version, buildversion=build)])

    def test_installed_exact_final_runtime_does_not_download(self):
        result, files, calls = self.run_fixture("fail", self.runtime(), {"runtimes": []})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])
        self.assertIn("runtime-selection.txt", files)

    def test_version_failure_can_request_the_same_final_build(self):
        result, files, calls = self.run_fixture("fallback", {"runtimes": []}, self.runtime())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["-downloadPlatform iOS -buildVersion 26.0", "-downloadPlatform iOS -buildVersion 23A343"])
        self.assertIn("Version request exit: 70", files["runtime-download-status.txt"])
        self.assertIn("Build request exit: 0", files["runtime-download-status.txt"])

    def test_failed_downloads_keep_inventory_and_failure_status(self):
        result, files, _ = self.run_fixture("fail", {"runtimes": []}, self.runtime())
        self.assertEqual(result.returncode, 70)
        self.assertIn("runtimes-after.json", files)
        self.assertNotIn("runtime-selection.txt", files)

    def test_newer_patch_or_beta_does_not_satisfy_requested_final_runtime(self):
        for runtime in [self.runtime(version="26.0.1", build="23A8464"), self.runtime(build="23A5260l")]:
            result, files, calls = self.run_fixture("success", {"runtimes": []}, runtime)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(calls, ["-downloadPlatform iOS -buildVersion 26.0"])
            self.assertIn("runtimes-after.json", files)
            self.assertNotIn("runtime-selection.txt", files)


if __name__ == "__main__":
    unittest.main()
