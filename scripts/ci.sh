#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
source "$root/scripts/ci_command.sh"
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
  # Each CI suite builds its own signed host on an independent runner. The
  # standalone full entry point also prepares this host before running tests.
  run_ci_command test-host-build 720 "$evidence/test-host-build.log" \
    xcodebuild build-for-testing -project Snowlit.xcodeproj -scheme Snowlit \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$root/build/app-$kind" -clonedSourcePackagesDirPath "$packages" \
    "${simulator_signing[@]}"
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
run_ci_command core-build 180 "$evidence/core-build.log" \
  swift build --package-path Packages/SnowlitKit --target SnowlitCore \
  --sdk "$core_sdk" --triple "$core_triple" \
  --scratch-path "$root/build/core-$kind"

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
  python3 scripts/create_simulator.py "$device" "$runtime_id" "$evidence/simulator.json"
simulator="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["udid"])' "$evidence/simulator.json")"
run_ci_command simulator-boot 45 "$evidence/simulator-boot.log" xcrun simctl boot "$simulator"
run_ci_command simulator-ready 240 "$evidence/simulator-ready.log" xcrun simctl bootstatus "$simulator" -b
printf 'Simulator boot completed. Starting Package and App baseline checks.\n'
destination="platform=iOS Simulator,id=$simulator"

if [ "$kind" = phone ]; then
  (
    cd Packages/SnowlitKit
    # Xcode generates this aggregate scheme from the fixed Package name.
    # The test command validates it; a separate scheme listing can stall before
    # any tests execute and adds no coverage.
    package_scheme="SnowlitKit-Package"
    printf 'Testing Package scheme: %s\n' "$package_scheme"
    run_ci_command package-tests 600 "$evidence/storage-tests.log" \
      xcodebuild test -scheme "$package_scheme" -destination "$destination" \
      -derivedDataPath "$root/build/package-tests" \
      -clonedSourcePackagesDirPath "$packages" \
      -resultBundlePath "$evidence/StorageTests.xcresult" \
      -only-testing:SnowlitCoreTests -only-testing:SnowlitStorageTests -only-testing:YingxueKitTests \
      -parallel-testing-enabled NO -test-timeouts-enabled YES \
      -maximum-test-execution-time-allowance 120 CODE_SIGNING_ALLOWED=NO
  )
fi

printf 'Package checks completed. Starting App startup and credential tests.\n'
test_selection=(-only-testing:SnowlitAppTests/StartupModelTests -only-testing:SnowlitAppTests/CredentialStoreTests -only-testing:SnowlitAppTests/SourceLibraryModelTests -only-testing:SnowlitAppTests/SourceManagementModelTests -only-testing:SnowlitAppTests/SourceAuthenticationModelTests -only-testing:SnowlitAppTests/SourceFormModelTests -only-testing:SnowlitAppTests/SourceFileInspectorTests -only-testing:SnowlitAppTests/SourceBrowsingModelTests -only-testing:SnowlitUITests/StartupUITests)
if [ "$kind" = tablet ]; then
  test_selection=(-only-testing:SnowlitUITests/StartupUITests)
fi
run_ci_command app-startup-tests 300 "$evidence/app-tests.log" \
  xcodebuild test-without-building -project Snowlit.xcodeproj -scheme Snowlit \
  -configuration Debug -destination "$destination" \
  -derivedDataPath "$root/build/app-$kind" \
  -clonedSourcePackagesDirPath "$packages" \
  -resultBundlePath "$evidence/AppTests.xcresult" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 120 \
  "${test_selection[@]}" "${simulator_signing[@]}"

app="$root/build/app-$kind/Build/Products/Debug-iphonesimulator/Snowlit.app"
plutil -convert json -o "$evidence/app-info.json" "$app/Info.plist"
run_ci_command app-install 60 "$evidence/app-install.log" xcrun simctl install "$simulator" "$app"
run_ci_command app-launch 30 "$evidence/launch.log" xcrun simctl launch "$simulator" io.github.bemarkt.snowlit

if [ "$kind" = phone ] && [ "$scope" = full ]; then
  # Standalone full runs retain the device build. The workflow runs the same
  # command in a separate job so it does not delay simulator behavior checks.
  bash scripts/build_release.sh
fi

printf 'Baseline checks passed for %s at %s (scope: %s).\n' "$kind" "$(git rev-parse HEAD)" "$scope" \
  | tee "$evidence/result.txt"
