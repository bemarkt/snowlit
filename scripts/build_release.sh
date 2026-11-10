#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
source "$root/scripts/ci_command.sh"
evidence="$root/build/evidence/release"
mkdir -p "$evidence"
python3 -m unittest discover -v -s scripts/tests -p 'test_package_ipa.py' \
  2>&1 | tee "$evidence/ipa-tool-tests.log"
{
  git rev-parse HEAD
  git status --porcelain
  xcodebuild -version
  xcrun swift --version
  xcodebuild -showsdks
  sw_vers
  uname -m
  printf 'Runner image: %s / %s\n' "${ImageOS:-local}" "${ImageVersion:-local}"
  printf 'Run: %s / attempt %s\n' "${GITHUB_RUN_ID:-local}" "${GITHUB_RUN_ATTEMPT:-local}"
  printf 'Scope: unsigned Release device build; no simulator or device execution.\n'
} | tee "$evidence/environment.txt"

printf 'Starting the Release device build at %s.\n' "$(date -u +%FT%TZ)"
run_ci_command release-build 900 "$evidence/release-build.log" \
  xcodebuild build -project Snowlit.xcodeproj -scheme Snowlit \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$root/build/release" \
    -clonedSourcePackagesDirPath "$root/build/SourcePackages" \
    -showBuildTimingSummary CODE_SIGNING_ALLOWED=NO

release_app="$root/build/release/Build/Products/Release-iphoneos/Snowlit.app"
plutil -convert json -o "$evidence/release-info.json" "$release_app/Info.plist"
lipo -info "$release_app/Snowlit" | tee "$evidence/release-architecture.txt"
if codesign -d "$release_app" > "$evidence/signing.txt" 2>&1; then
  printf 'Expected an unsigned device build.\n' >&2
  exit 1
fi
if ! grep -Fq 'code object is not signed at all' "$evidence/signing.txt"; then
  cat "$evidence/signing.txt" >&2
  exit 1
fi
python3 scripts/package_ipa.py "$release_app" "$root/build/ipa" \
  | tee "$evidence/ipa-verification.json"
printf 'Unsigned Release device build and IPA packaging passed at %s.\n' "$(git rev-parse HEAD)" \
  | tee "$evidence/result.txt"
