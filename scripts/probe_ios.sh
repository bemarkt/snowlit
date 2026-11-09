#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
kind="${1:-}"
mode="${2:-integration}"
case "$kind" in
  phone) device="iPhone 17" ;;
  tablet) device="iPad (A16)" ;;
  *) printf 'Usage: bash scripts/probe_ios.sh phone|tablet\n' >&2; exit 2 ;;
esac
case "$mode" in
  integration) selection=(-only-testing:YingxueKitTests -only-testing:YingxueWebKitTests) ;;
  recovery) selection=(-only-testing:YingxueRecoveryTests) ;;
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
    if path.is_file() and (str(path).startswith("Packages/") or str(path).startswith("scripts/")):
        records.append({"path": path.as_posix(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
pathlib.Path(sys.argv[1]).write_text(json.dumps(records, indent=2) + "\n")
PY

node --test scripts/probes/site.test.mjs > "$evidence/fixture-tests.log" 2>&1
fixture_pid=""
simulator=""
cleanup() {
  result=$?
  trap - EXIT
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
  "com.apple.CoreSimulator.SimRuntime.iOS-26-5" "$evidence/simulator.json")"
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b

cd Packages/SnowlitKit
xcodebuild -list -json > "$evidence/package-schemes.json"
package_scheme="$(python3 - "$evidence/package-schemes.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
schemes = [s for entry in data.values() if isinstance(entry, dict) for s in entry.get("schemes", [])]
for name in ("SnowlitKit-Package", "SnowlitKit"):
    if name in schemes:
        print(name)
        break
else:
    raise SystemExit(f"Package test scheme not found: {schemes}")
PY
)"
python3 "$root/scripts/probes/supervise.py" --timeout 900 --log "$evidence/webkit-tests.log" -- \
  xcodebuild test -scheme "$package_scheme" -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath "$root/build/runtime-$kind-$mode" -resultBundlePath "$evidence/RuntimeTests.xcresult" \
  "${selection[@]}" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO
printf 'Selected integration tests passed at %s\n' "$(git rev-parse HEAD)" > "$evidence/result.txt"
