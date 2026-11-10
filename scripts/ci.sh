#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
kind="$1"
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
} > "$evidence/environment.txt"
cat "$evidence/environment.txt"
runtime_version="${SNOWLIT_IOS_RUNTIME:-26.5}"
bash scripts/prepare_runtime.sh "$runtime_version" "$evidence"
runtime_id="com.apple.CoreSimulator.SimRuntime.iOS-${runtime_version//./-}"

python3 scripts/check_structure.py | tee "$evidence/structure.log"
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
    xcodebuild -list -json > "$evidence/package-schemes.json"
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
      -resultBundlePath "$evidence/StorageTests.xcresult" \
      -only-testing:SnowlitCoreTests -only-testing:SnowlitStorageTests -only-testing:YingxueKitTests \
      -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
      2>&1 | tee "$evidence/storage-tests.log"
  )
fi

test_selection=(-only-testing:SnowlitAppTests/StartupModelTests -only-testing:SnowlitUITests/StartupUITests)
if [ "$kind" = tablet ]; then
  test_selection=(-only-testing:SnowlitUITests/StartupUITests)
fi
xcodebuild test -project Snowlit.xcodeproj -scheme Snowlit \
  -configuration Debug -destination "$destination" \
  -derivedDataPath "$root/build/app-$kind" \
  -resultBundlePath "$evidence/AppTests.xcresult" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 120 \
  "${test_selection[@]}" CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$evidence/app-tests.log"

app="$root/build/app-$kind/Build/Products/Debug-iphonesimulator/Snowlit.app"
plutil -convert json -o "$evidence/app-info.json" "$app/Info.plist"
xcrun simctl install "$simulator" "$app"
xcrun simctl launch "$simulator" io.github.bemarkt.snowlit \
  | tee "$evidence/launch.log"

if [ "$kind" = phone ]; then
  xcodebuild build -project Snowlit.xcodeproj -scheme Snowlit \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$root/build/release" CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$evidence/release-build.log"
  release_app="$root/build/release/Build/Products/Release-iphoneos/Snowlit.app"
  plutil -convert json -o "$evidence/release-info.json" "$release_app/Info.plist"
  lipo -info "$release_app/Snowlit" | tee "$evidence/release-architecture.txt"
fi

printf 'All required checks passed for %s at %s\n' "$kind" "$(git rev-parse HEAD)" \
  | tee "$evidence/result.txt"
