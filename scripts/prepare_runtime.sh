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
valid = len(matches) == 1 and matches[0]['version'] == sys.argv[2]
if valid and sys.argv[2] == '26.0':
    valid = matches[0]['buildversion'] == '23A343'
sys.exit(0 if valid else 1)
PY
}
download_status=0
if ! runtime_available "$evidence/runtimes-before.json"; then
  # A requested minimum runtime must actually be installed; no newer fallback.
  if xcodebuild -downloadPlatform iOS -buildVersion "$version" \
    2>&1 | tee "$evidence/runtime-download.log"; then
    download_status=0
  else
    download_status=$?
    printf 'Version request exit: %s\n' "$download_status" > "$evidence/runtime-download-status.txt"
    if [ "$version" = 26.0 ]; then
      # Apple's simulator index identifies the final 26.0 runtime as 23A343.
      # https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex
      # Request the same runtime by build ID if version lookup is unavailable.
      if xcodebuild -downloadPlatform iOS -buildVersion 23A343 \
        2>&1 | tee "$evidence/runtime-download-build.log"; then
        download_status=0
      else
        download_status=$?
      fi
      printf 'Build request exit: %s\n' "$download_status" >> "$evidence/runtime-download-status.txt"
    fi
  fi
fi
xcrun simctl list runtimes -j > "$evidence/runtimes-after.json"
if [ "$download_status" -ne 0 ]; then exit "$download_status"; fi
runtime_available "$evidence/runtimes-after.json"
printf 'Verified requested iOS runtime: %s\n' "$version" > "$evidence/runtime-selection.txt"
