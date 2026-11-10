#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
kind="${1:-}"
mode="${2:-integration}"
runtime_version="${SNOWLIT_IOS_RUNTIME:-26.5}"
case "$runtime_version" in
  26.0|26.5) runtime_id="com.apple.CoreSimulator.SimRuntime.iOS-${runtime_version//./-}" ;;
  *) printf 'Unsupported simulator runtime: %s\n' "$runtime_version" >&2; exit 2 ;;
esac
case "$kind" in
  phone) device="iPhone 17" ;;
  tablet) device="iPad (A16)" ;;
  *) printf 'Usage: bash scripts/probe_ios.sh phone|tablet\n' >&2; exit 2 ;;
esac
case "$mode" in
  integration) selection=(-only-testing:SnowlitAppTests/WebKitRuntimeProbeTests -only-testing:SnowlitAppTests/ReaderProbeTests) ;;
  recovery) selection=(-only-testing:SnowlitAppTests/WebKitRecoveryTests) ;;
  *) printf 'Unknown probe mode: %s\n' "$mode" >&2; exit 2 ;;
esac

evidence="$root/build/evidence/runtime-$kind-$mode"
mkdir -p "$evidence"
{
  git rev-parse HEAD
  git status --porcelain
  xcodebuild -version
  xcrun swift --version
  node --version
  sw_vers
  printf 'Runner image: %s / %s\n' "${ImageOS:-local}" "${ImageVersion:-local}"
  printf 'Run: %s / attempt %s\n' "${GITHUB_RUN_ID:-local}" "${GITHUB_RUN_ATTEMPT:-local}"
} > "$evidence/environment.txt"
python3 - "$evidence/source-digests.json" <<'PY'
import hashlib, json, pathlib, subprocess, sys
files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
records = []
for raw in sorted(set(files.split(b"\0")) - {b""}):
    path = pathlib.Path(raw.decode())
    if path.is_file() and path.suffix in (".swift", ".c", ".sh", ".py", ".mjs", ".pbxproj", ".xcscheme", ".yml"):
        records.append({"path": path.as_posix(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
pathlib.Path(sys.argv[1]).write_text(json.dumps(records, indent=2) + "\n")
PY

node --test scripts/probes/site.test.mjs > "$evidence/fixture-tests.log" 2>&1
export SNOWLIT_PROCESS_SAMPLER="$root/build/process-snapshot"
xcrun --sdk macosx clang -std=c11 -O2 -Wall -Wextra -Werror \
  scripts/probes/process_snapshot.c -lproc -o "$SNOWLIT_PROCESS_SAMPLER" \
  > "$evidence/sampler-build.log" 2>&1
python3 -m unittest discover -s scripts/probes -p 'test_*.py' \
  > "$evidence/probe-tool-tests.log" 2>&1
fixture_pid=""
simulator=""
probe_complete=false
cleanup() {
  result=$?
  trap - EXIT
  if [ "$result" -eq 0 ] && [ "$probe_complete" != true ]; then
    result=1
  fi
  if [ -n "$simulator" ]; then
    xcrun simctl shutdown "$simulator" || true
    xcrun simctl delete "$simulator" || true
  fi
  if [ -n "$fixture_pid" ]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  printf 'Exit status: %s\n' "$result" > "$evidence/script-status.txt"
  exit "$result"
}
trap cleanup EXIT
node scripts/probes/site.mjs 18731 > "$evidence/fixture.log" 2>&1 &
fixture_pid=$!
python3 - "$fixture_pid" "$evidence/fixture.log" <<'PY'
import json, os, pathlib, sys, time, urllib.request
pid = int(sys.argv[1])
deadline = time.monotonic() + 10
while True:
    os.kill(pid, 0)
    try:
        # The child logs only after listen succeeds. Match its identity, so a stale
        # server on the same port cannot satisfy readiness for a failed child.
        started = json.loads(pathlib.Path(sys.argv[2]).read_text())
        with urllib.request.urlopen("http://127.0.0.1:18731/health", timeout=1) as response:
            health = json.load(response)
            assert health["fixtureVersion"] == "runtime-probe-1"
            assert health["instanceID"] == started["instanceID"]
        break
    except (OSError, json.JSONDecodeError):
        if time.monotonic() >= deadline:
            raise
        time.sleep(0.05)
PY
simulator="$(python3 scripts/create_simulator.py "$device" \
  "$runtime_id" "$evidence/simulator.json")"
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b

xcodebuild -list -json -project Snowlit.xcodeproj > "$evidence/project-schemes.json"
supervision=(python3 "$root/scripts/probes/supervise.py" --timeout 900 --log "$evidence/webkit-tests.log")
if [ "$mode" = recovery ]; then
  supervision+=(--process-samples "$evidence/process-samples.jsonl" --process-sampler "$SNOWLIT_PROCESS_SAMPLER")
fi
"${supervision[@]}" -- \
  xcodebuild test -project Snowlit.xcodeproj -scheme Snowlit -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath "$root/build/app-$kind" -resultBundlePath "$evidence/RuntimeTests.xcresult" \
  "${selection[@]}" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO
python3 "$root/scripts/probes/verify_execution.py" "$evidence" "$mode"
printf 'Selected integration tests passed at %s\n' "$(git rev-parse HEAD)" > "$evidence/result.txt"
probe_complete=true
