#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
kind="$1"
scope="${2:-full}"
case "$scope" in
  full|prepare|baseline) ;;
  *) printf 'Unknown verification scope: %s\n' "$scope" >&2; exit 2 ;;
esac
case "$kind" in
  phone) device="iPhone 17" ;;
  tablet) device="iPad (A16)" ;;
  *) printf 'Usage: bash scripts/ci.sh phone|tablet\n' >&2; exit 2 ;;
esac

evidence="$root/build/evidence/$kind"
mkdir -p "$evidence"
{
  git rev-parse HEAD
  git status --porcelain
  xcodebuild -version
  xcrun swift --version
  xcodebuild -showsdks
  sw_vers
  uname -m
  printf 'Runner image: %s\n' "${ImageOS:-local}"
  printf 'Runner image version: %s\n' "${ImageVersion:-local}"
  printf 'Run ID: %s\n' "${GITHUB_RUN_ID:-local}"
  printf 'Run attempt: %s\n' "${GITHUB_RUN_ATTEMPT:-local}"
  printf 'Task: %s / preparation scope: %s\n' "${SNOWLIT_CI_TASK:-verify}" "$scope"
} > "$evidence/environment.txt"
cat "$evidence/environment.txt"
python3 scripts/generate_yingxue.py --check | tee "$evidence/contract-generation.log"
node --test protocols/yingxue/contract.test.mjs | tee "$evidence/contract-tests.log"
runtime_version="${SNOWLIT_IOS_RUNTIME:-26.5}"
bash scripts/prepare_runtime.sh "$runtime_version" "$evidence"
runtime_id="com.apple.CoreSimulator.SimRuntime.iOS-${runtime_version//./-}"

python3 scripts/check_structure.py | tee "$evidence/structure.log"
packages="$root/build/SourcePackages"
source "$root/scripts/simulator_signing.sh"
prepare_simulator_signing
if [ "$scope" != baseline ]; then
  # Build the shared host before running any suites. In CI, the separate prepare
  # step lets independent probes still run if a baseline behavior test fails.
  xcodebuild build-for-testing -project Snowlit.xcodeproj -scheme Snowlit \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$root/build/app-$kind" -clonedSourcePackagesDirPath "$packages" \
    "${simulator_signing[@]}" 2>&1 | tee "$evidence/test-host-build.log"
  record_simulator_signing
fi
if [ "$scope" = prepare ]; then
  printf 'Test host prepared at %s; no baseline tests or Release build were run.\n' \
    "$(git rev-parse HEAD)" > "$evidence/preparation.txt"
  exit 0
fi
core_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
core_triple="$(uname -m)-apple-ios26.0-simulator"
printf 'Target: %s\nSDK: %s\n' "$core_triple" "$core_sdk" > "$evidence/core-destination.txt"
swift build --package-path Packages/SnowlitKit --target SnowlitCore \
  --sdk "$core_sdk" --triple "$core_triple" \
  --scratch-path "$root/build/core-$kind" 2>&1 | tee "$evidence/core-build.log"

simulator=""
cleanup() {
  if [ -n "$simulator" ]; then
    xcrun simctl shutdown "$simulator" || true
    xcrun simctl delete "$simulator" || true
  fi
}
trap cleanup EXIT
simulator="$(python3 scripts/create_simulator.py "$device" \
  "$runtime_id" "$evidence/simulator.json")"
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
destination="platform=iOS Simulator,id=$simulator"

if [ "$kind" = phone ]; then
  (
    cd Packages/SnowlitKit
    xcodebuild -list -json -clonedSourcePackagesDirPath "$packages" > "$evidence/package-schemes.json"
    package_scheme="$(python3 - "$evidence/package-schemes.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
schemes = [s for entry in data.values() if isinstance(entry, dict)
           for s in entry.get("schemes", [])]
for name in ("SnowlitKit-Package", "SnowlitKit"):
    if name in schemes:
        print(name)
        break
else:
    raise SystemExit(f"Package test scheme not found: {schemes}")
PY
)"
    xcodebuild test -scheme "$package_scheme" -destination "$destination" \
      -derivedDataPath "$root/build/package-tests" \
      -clonedSourcePackagesDirPath "$packages" \
      -resultBundlePath "$evidence/StorageTests.xcresult" \
      -only-testing:SnowlitCoreTests -only-testing:SnowlitStorageTests -only-testing:YingxueKitTests \
      -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
      2>&1 | tee "$evidence/storage-tests.log"
  )
fi

test_selection=(-only-testing:SnowlitAppTests/StartupModelTests -only-testing:SnowlitAppTests/CredentialStoreTests -only-testing:SnowlitUITests/StartupUITests)
if [ "$kind" = tablet ]; then
  test_selection=(-only-testing:SnowlitUITests/StartupUITests)
fi
xcodebuild test-without-building -project Snowlit.xcodeproj -scheme Snowlit \
  -configuration Debug -destination "$destination" \
  -derivedDataPath "$root/build/app-$kind" \
  -clonedSourcePackagesDirPath "$packages" \
  -resultBundlePath "$evidence/AppTests.xcresult" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 120 \
  "${test_selection[@]}" "${simulator_signing[@]}" \
  2>&1 | tee "$evidence/app-tests.log"

app="$root/build/app-$kind/Build/Products/Debug-iphonesimulator/Snowlit.app"
plutil -convert json -o "$evidence/app-info.json" "$app/Info.plist"
xcrun simctl install "$simulator" "$app"
xcrun simctl launch "$simulator" io.github.bemarkt.snowlit \
  | tee "$evidence/launch.log"

if [ "$kind" = phone ]; then
  xcodebuild build -project Snowlit.xcodeproj -scheme Snowlit \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$root/build/release" -clonedSourcePackagesDirPath "$packages" CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$evidence/release-build.log"
  release_app="$root/build/release/Build/Products/Release-iphoneos/Snowlit.app"
  plutil -convert json -o "$evidence/release-info.json" "$release_app/Info.plist"
  lipo -info "$release_app/Snowlit" | tee "$evidence/release-architecture.txt"
fi

printf 'All required checks passed for %s at %s\n' "$kind" "$(git rev-parse HEAD)" \
  | tee "$evidence/result.txt"
