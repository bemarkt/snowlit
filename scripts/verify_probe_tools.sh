#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
evidence="$PWD/build/evidence/probe-tools"
mkdir -p "$evidence"
{
  git rev-parse HEAD
  xcodebuild -version
  python3 --version
  node --version
  sw_vers
  printf 'Run: %s / attempt %s\n' "${GITHUB_RUN_ID:-local}" "${GITHUB_RUN_ATTEMPT:-local}"
} | tee "$evidence/environment.txt"

printf 'Checking synthetic website fixtures.\n'
node --test scripts/probes/site.test.mjs scripts/probes/worker.test.mjs scripts/probes/source_execution.test.mjs 2>&1 | tee "$evidence/fixture-tests.log"
export SNOWLIT_PROCESS_SAMPLER="$PWD/build/process-snapshot"
printf 'Building the native process sampler.\n'
xcrun --sdk macosx clang -std=c11 -O2 -Wall -Wextra -Werror \
  scripts/probes/process_snapshot.c -lproc -o "$SNOWLIT_PROCESS_SAMPLER" \
  2>&1 | tee "$evidence/sampler-build.log"
printf 'Checking supervision, sampling and interruption tools.\n'
python3 -m unittest discover -v -s scripts/probes -p 'test_*.py' \
  2>&1 | tee "$evidence/probe-tool-tests.log"
printf 'Verification tooling passed at %s\n' "$(git rev-parse HEAD)" | tee "$evidence/result.txt"
