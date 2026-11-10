#!/bin/bash
set -euo pipefail

version="$1"
evidence="$2"
case "$version" in
  26.0|26.5) ;;
  *) printf 'Unsupported simulator runtime: %s\n' "$version" >&2; exit 2 ;;
esac
mkdir -p "$evidence"
xcrun simctl list runtimes -j > "$evidence/runtimes-before.json"
runtime_available() {
  python3 - "$1" "$version" <<'PY'
import json, sys
inventory = json.load(open(sys.argv[1]))
identifier = 'com.apple.CoreSimulator.SimRuntime.iOS-' + sys.argv[2].replace('.', '-')
matches = [r for r in inventory['runtimes'] if r['identifier'] == identifier and r['isAvailable']]
sys.exit(0 if len(matches) == 1 and matches[0]['version'] == sys.argv[2] else 1)
PY
}
if ! runtime_available "$evidence/runtimes-before.json"; then
  # A requested minimum runtime must actually be installed; no newer fallback.
  xcodebuild -downloadPlatform iOS -buildVersion "$version" \
    2>&1 | tee "$evidence/runtime-download.log"
fi
xcrun simctl list runtimes -j > "$evidence/runtimes-after.json"
runtime_available "$evidence/runtimes-after.json"
printf 'Verified requested iOS runtime: %s\n' "$version" > "$evidence/runtime-selection.txt"
