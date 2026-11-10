#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
source "$root/scripts/ci_command.sh"
evidence="$root/build/evidence/release"
mkdir -p "$evidence"
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
printf 'Unsigned Release device build passed at %s.\n' "$(git rev-parse HEAD)" \
  | tee "$evidence/result.txt"
