#!/bin/bash
# Source from the repository root after defining the evidence directory.
run_ci_command() {
  local label="$1" limit="$2" log="$3"
  shift 3
  printf '[%s] Starting; command deadline is %s seconds.\n' "$label" "$limit"
  python3 "$root/scripts/probes/supervise.py" \
    --label "$label" --timeout "$limit" --log "$log" -- "$@"
}
