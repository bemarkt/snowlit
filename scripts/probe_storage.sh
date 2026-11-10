#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
source "$root/scripts/ci_command.sh"
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
sampler="$root/build/process-snapshot"
if [ "${SNOWLIT_PROBE_TOOLS_PREPARED:-false}" != true ]; then
  bash scripts/verify_probe_tools.sh
fi
test -x "$sampler"
simulator=""
cleanup() {
  result=$?
  trap - EXIT
  if [ -n "$simulator" ]; then
    run_ci_command simulator-shutdown 30 "$evidence/simulator-shutdown.log" xcrun simctl shutdown "$simulator" \
      || { if [ "$result" -eq 0 ]; then result=1; fi; }
    run_ci_command simulator-delete 30 "$evidence/simulator-delete.log" xcrun simctl delete "$simulator" \
      || { if [ "$result" -eq 0 ]; then result=1; fi; }
  fi
  printf 'Exit status: %s\n' "$result" > "$evidence/script-status.txt"
  exit "$result"
}
trap cleanup EXIT
run_ci_command simulator-create 75 "$evidence/simulator-create.log" \
  python3 scripts/create_simulator.py 'iPhone 17' "$runtime_id" "$evidence/simulator.json"
simulator="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["udid"])' "$evidence/simulator.json")"
run_ci_command simulator-boot 45 "$evidence/simulator-boot.log" xcrun simctl boot "$simulator"
run_ci_command simulator-ready 240 "$evidence/simulator-ready.log" xcrun simctl bootstatus "$simulator" -b
printf 'Simulator boot completed. Installing the storage probe App.\n'
run_ci_command storage-app-install 60 "$evidence/app-install.log" xcrun simctl install "$simulator" "$app"
printf 'App installed. Starting 24 storage interruption trials.\n'
run_ci_command storage-interruptions 900 "$evidence/storage-tests.log" \
  python3 scripts/probes/storage_process.py "$simulator" "$sampler" "$evidence"
printf '24 interruption trials and two fresh reopens each passed at %s\n' "$(git rev-parse HEAD)" \
  > "$evidence/result.txt"
