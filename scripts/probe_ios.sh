#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
source "$root/scripts/ci_command.sh"
kind="${1:-}"
mode="${2:-integration}"
source "$root/scripts/simulator_signing.sh"
prepare_simulator_signing
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
test_timeout=60
case "$mode" in
  integration) selection=(-only-testing:SnowlitAppTests/WebKitRuntimeProbeTests -only-testing:SnowlitAppTests/ReaderProbeTests -only-testing:SnowlitAppTests/SourceContractProbeTests -only-testing:SnowlitAppTests/SourceCandidateValidatorTests -only-testing:SnowlitUITests/LibraryFlowUITests) ;;
  recovery) selection=(-only-testing:SnowlitAppTests/WebKitRecoveryTests) ;;
  reader-ui) selection=(-only-testing:SnowlitUITests/ReaderInteractionUITests); test_timeout=120 ;;
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

export SNOWLIT_PROCESS_SAMPLER="$root/build/process-snapshot"
# CI runs these common prerequisites before building the App. Standalone probe
# invocations perform the same checks and preserve their shared evidence.
if [ "${SNOWLIT_PROBE_TOOLS_PREPARED:-false}" != true ]; then
  bash scripts/verify_probe_tools.sh
fi
test -x "$SNOWLIT_PROCESS_SAMPLER"
fixture_pid=""
simulator=""
probe_complete=false
cleanup() {
  result=$?
  trap - EXIT
  if [ "$result" -eq 0 ] && [ "$probe_complete" != true ]; then
    result=1
  fi
  if [ "$mode" = reader-ui ] && [ -f "$evidence/RuntimeTests.xcresult/Info.plist" ]; then
    if ! run_ci_command attachment-export 60 "$evidence/attachment-export.log" \
      xcrun xcresulttool export attachments --path "$evidence/RuntimeTests.xcresult" \
      --output-path "$evidence/attachments"; then
      printf 'Reader screenshot export failed; see attachment-export.log\n' >&2
      result=1
    fi
  fi
  if [ -n "$simulator" ]; then
    run_ci_command simulator-shutdown 30 "$evidence/simulator-shutdown.log" xcrun simctl shutdown "$simulator" \
      || { if [ "$result" -eq 0 ]; then result=1; fi; }
    run_ci_command simulator-delete 30 "$evidence/simulator-delete.log" xcrun simctl delete "$simulator" \
      || { if [ "$result" -eq 0 ]; then result=1; fi; }
  fi
  if [ -n "$fixture_pid" ]; then
    # The fixture is this shell's direct child. It installs no shutdown handler
    # and has no persistent data, so cleanup need not wait for graceful draining.
    kill -KILL "$fixture_pid" 2>/dev/null || true
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
run_ci_command simulator-create 75 "$evidence/simulator-create.log" \
  python3 scripts/create_simulator.py "$device" "$runtime_id" "$evidence/simulator.json"
simulator="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["udid"])' "$evidence/simulator.json")"
run_ci_command simulator-boot 45 "$evidence/simulator-boot.log" xcrun simctl boot "$simulator"
run_ci_command simulator-ready 240 "$evidence/simulator-ready.log" xcrun simctl bootstatus "$simulator" -b
printf 'Simulator boot completed. Starting %s tests; test output follows.\n' "$mode"

supervision=(python3 "$root/scripts/probes/supervise.py" --label "$mode-tests" --timeout 900 --log "$evidence/webkit-tests.log")
if [ "$mode" = recovery ]; then
  supervision+=(--process-samples "$evidence/process-samples.jsonl" --process-sampler "$SNOWLIT_PROCESS_SAMPLER" --allow-test-termination)
fi
"${supervision[@]}" -- \
  xcodebuild test-without-building -project Snowlit.xcodeproj -scheme Snowlit -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath "$root/build/app-$kind" -resultBundlePath "$evidence/RuntimeTests.xcresult" \
  -clonedSourcePackagesDirPath "$root/build/SourcePackages" \
  "${selection[@]}" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance "$test_timeout" "${simulator_signing[@]}"
python3 "$root/scripts/probes/verify_execution.py" "$evidence" "$mode"
printf 'Selected integration tests passed at %s\n' "$(git rev-parse HEAD)" > "$evidence/result.txt"
probe_complete=true
