#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
evidence="$root/build/evidence/storage-phone-process"
mkdir -p "$evidence"
runtime_version="${SNOWLIT_IOS_RUNTIME:-26.5}"
case "$runtime_version" in
  26.0|26.5) runtime_id="com.apple.CoreSimulator.SimRuntime.iOS-${runtime_version//./-}" ;;
  *) printf 'Unsupported runtime: %s\n' "$runtime_version" >&2; exit 2 ;;
esac
{
  git rev-parse HEAD
  git status --porcelain
  xcodebuild -version
  xcrun swift --version
  sw_vers
  printf 'Runner image: %s / %s\n' "${ImageOS:-local}" "${ImageVersion:-local}"
  printf 'Run: %s / attempt %s\n' "${GITHUB_RUN_ID:-local}" "${GITHUB_RUN_ATTEMPT:-local}"
} > "$evidence/environment.txt"
app="$root/build/app-phone/Build/Products/Debug-iphonesimulator/Snowlit.app"
python3 - "$evidence/source-digests.json" "$app/Snowlit" "$evidence/app-digest.json" <<'PY'
import hashlib, json, pathlib, subprocess, sys
files = subprocess.check_output(["git", "ls-files", "-z"]).split(b"\0")
records = []
for raw in sorted(set(files) - {b""}):
    path = pathlib.Path(raw.decode())
    if path.is_file() and path.suffix in (".swift", ".c", ".sh", ".py", ".mjs", ".pbxproj", ".xcscheme", ".yml"):
        records.append(dict(path=path.as_posix(), sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
pathlib.Path(sys.argv[1]).write_text(json.dumps(records, indent=2) + "\n")
pathlib.Path(sys.argv[3]).write_text(json.dumps(dict(configuration="Debug", binarySHA256=
    hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest()), indent=2) + "\n")
PY
sampler="$root/build/storage-process-snapshot"
xcrun --sdk macosx clang -std=c11 -O2 -Wall -Wextra -Werror \
  scripts/probes/process_snapshot.c -lproc -o "$sampler" \
  > "$evidence/sampler-build.log" 2>&1
simulator=""
cleanup() {
  result=$?
  trap - EXIT
  if [ -n "$simulator" ]; then
    xcrun simctl shutdown "$simulator" || true
    xcrun simctl delete "$simulator" || true
  fi
  printf 'Exit status: %s\n' "$result" > "$evidence/script-status.txt"
  exit "$result"
}
trap cleanup EXIT
simulator="$(python3 scripts/create_simulator.py 'iPhone 17' "$runtime_id" "$evidence/simulator.json")"
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
printf 'Simulator boot completed. Installing the storage probe App.\n'
xcrun simctl install "$simulator" "$app"
printf 'App installed. Starting 24 storage interruption trials.\n'
python3 scripts/probes/supervise.py --timeout 900 --log "$evidence/storage-tests.log" -- \
  python3 scripts/probes/storage_process.py "$simulator" "$sampler" "$evidence"
printf '24 interruption trials and two fresh reopens each passed at %s\n' "$(git rev-parse HEAD)" \
  > "$evidence/result.txt"
